/**
 * VehicleStatusHandler
 * --------------------
 * Purpose
 *  - Persist incoming telemetry from Platform Event Vehicle_Status__e
 *    onto Vehicle__c records (by VIN, optionally scoped by AccountId__c).
 *  - This makes LWC reads idempotent and durable across refreshes
 *    (the dashboard queries Vehicle__c, not transient event payloads).
 *
 * Design notes
 *  - Bulk-safe: processes Trigger.New as a list (no per-row SOQL/DML).
 *  - Selective query: filters by VIN (and Account__c if present) to avoid full scans.
 *  - Many-to-one: supports multiple Vehicle__c per VIN (edge cases like duplicates);
 *    updates *all* matches for that VIN in the same Account if AccountId is provided.
 *  - Security: enforces CRUD/FLS via Security.stripInaccessible on UPDATE path.
 *  - No inserts here: assumes Vehicles are pre-seeded in CRM. If required, see "Extensions."
 *
 * Failure modes & behavior
 *  - Missing VIN → event ignored (cannot correlate).
 *  - No matching Vehicle__c → ignored (safe; no false inserts).
 *  - Mixed batches with some malformed rows → valid rows still persist.
 *  - High-volume bursts → DML is chunked (BATCH_SIZE) to avoid limits.
 *
 * Extensions (safe places to add logic)
 *  - Upsert-not-found: when no Vehicle__c found, insert a new one if business agrees.
 *  - Telemetry history: insert a Vehicle_Status__c history record before updating the head.
 *  - Staleness guards: compare e.SourceTs__c vs LastStatusTs__c; drop out-of-order events.
 *  - Alerts: publish Platform Event/Notification when thresholds are breached (e.g., fuel < 10%).
 *  - Field-level allowlist: restrict which fields can be updated from external events.
 *
 * Operational guidance
 *  - Ensure VIN__c is Unique + External Id on Vehicle__c (enables fast lookup, clean semantics).
 *  - Consider an index on (Account__c, VIN__c) if VIN uniqueness is only within Account.
 *  - Keep the PE schema stable; changes should be backwards compatible or versioned.
 *
 * NEW: Cache invalidation (Platform Cache)
 *  - After successful updates, we now evict the Account-level SNAPSHOT cache key:
 *        key = 'acct' + AccountId + 'snapshot'
 *    so the next dashboard refresh returns a fresh payload and a new "Cached:" timestamp.
 *  - We intentionally do NOT try to evict paginated page keys (ps{size}tok{hash}); TTL will roll them off.
 *
 * NEW (2025-11-07): Fix regression where refresh/load-more reverted to pre-event values
 *  - Root cause: Even after evicting snapshot, other paginated page keys could remain valid.
 *  - Change: Introduce per-Account cache **version** (stored in Platform Cache). On each successful
 *    batch update we **bump the version**, making ALL prior keys obsolete. Controller embeds this
 *    version into every cache key and page token.
 */

 public with sharing class VehicleStatusHandler {
    // Chunk DML to avoid exceeding per-transaction limits on large batches.
    @TestVisible private static final Integer BATCH_SIZE = 200;

    // Platform Cache partition used by the controller
    private static final String ORG_PARTITION = 'ConnectedVehicles';

    // --- Helper: read page size from CMDT so legacy eviction (if used) matches controller keys ---
    @TestVisible private static Integer effectivePageSize() {
        Integer ps = 200; // default fallback (aligns with controller default)
        ConnectedVehicleSettings__mdt cfg = ConnectedVehicleSettings__mdt.getInstance('Default');
        if (cfg != null && cfg.PageSize__c != null) {
            try { ps = Integer.valueOf(cfg.PageSize__c); } catch (Exception ignore) {}
        }
        if (ps == null || ps <= 0) ps = 200;
        return ps;
    }

    // NEW: Bump per-account cache version to invalidate *all* old keys in one step.
    @TestVisible private static void bumpVersion(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;
        try {
            Cache.OrgPartition p = Cache.Org.getPartition(ORG_PARTITION);
            for (Id aId : accountIds) {
                String key = 'acct' + String.valueOf(aId) + ':ver';
                Integer curr = 1;
                Object o = p.get(key);
                if (o != null) curr = (Integer) o;
                Integer next = (curr == null || curr < 1 || curr > 1000000) ? 1 : curr + 1;
                p.put(key, next, 86400); // 24h TTL for version marker
            }
        } catch (Exception ignore) {
            // Best-effort only. If cache is down, UI falls back to TTL-based expiry.
        }
    }

    /**
     * Entry point from Vehicle_Status__e AFTER INSERT.
     * - Trigger is defined in VehicleStatusTrigger.
     * - Assumes High-Volume PE is used when traffic is high.
     */
    public static void handleAfterInsert(List<Vehicle_Status__e> events) {
        if (events == null || events.isEmpty()) return;

        // Collect VINs and (optional) AccountIds from events.
        // Rationale: drive a single, selective SOQL instead of N queries.
        Set<String> vins = new Set<String>();
        Set<String> acctIdsFromEvents = new Set<String>(); // may be empty; still useful for scoping query
        for (Vehicle_Status__e e : events) {
            if (String.isNotBlank(e.VIN__c)) vins.add(e.VIN__c);
            if (String.isNotBlank(e.AccountId__c)) acctIdsFromEvents.add(e.AccountId__c);
        }
        if (vins.isEmpty()) return; // nothing to correlate → nothing to do

        // Query matching Vehicles (filter by Account if provided).
        // NOTE: If VIN is globally unique, the Account__c IN filter can be removed for speed.
        List<Vehicle__c> targets;
        if (!acctIdsFromEvents.isEmpty()) {
            targets = [
                SELECT Id, VIN__c, Account__c,
                       FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
                FROM Vehicle__c
                WHERE VIN__c IN :vins AND Account__c IN :acctIdsFromEvents
            ];
        } else {
            targets = [
                SELECT Id, VIN__c, Account__c,
                       FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
                FROM Vehicle__c
                WHERE VIN__c IN :vins
            ];
        }
        if (targets.isEmpty()) return; // defensive: do not upsert by default

        // Build VIN → Vehicles map (supports multi-record matches per VIN) and collect affected Accounts.
        Map<String, List<Vehicle__c>> vinToVehicles = new Map<String, List<Vehicle__c>>();
        Set<Id> affectedAccountIds = new Set<Id>();
        for (Vehicle__c v : targets) {
            if (v.Account__c != null) affectedAccountIds.add(v.Account__c);

            List<Vehicle__c> listForVin = vinToVehicles.get(v.VIN__c);
            if (listForVin == null) {
                listForVin = new List<Vehicle__c>();
                vinToVehicles.put(v.VIN__c, listForVin);
            }
            listForVin.add(v);
        }

        // For each event, prepare an update for the matched vehicle(s).
        // TIP: If staleness checks are desired, compare e.SourceTs__c vs v.LastStatusTs__c here.
        List<Vehicle__c> updates = new List<Vehicle__c>();
        for (Vehicle_Status__e e : events) {
            List<Vehicle__c> listForVin = vinToVehicles.get(e.VIN__c);
            if (listForVin == null) continue;

            for (Vehicle__c v : listForVin) {
                Vehicle__c up = new Vehicle__c(Id = v.Id);

                // Event numeric fields arrive as Decimal in PE; cast to Integer fields on Vehicle__c.
                if (e.FuelLevelPct__c != null)
                    up.FuelLevelPct__c = Integer.valueOf((Decimal) e.FuelLevelPct__c);

                if (e.MileageKm__c != null)
                    up.MileageKm__c = Integer.valueOf((Decimal) e.MileageKm__c);

                if (String.isNotBlank(e.SoftwareVersion__c))
                    up.SoftwareVersion__c = e.SoftwareVersion__c;

                // Default timestamp to now if source didn't send one.
                up.LastStatusTs__c = (e.SourceTs__c == null) ? System.now() : e.SourceTs__c;

                updates.add(up);
            }
        }
        if (updates.isEmpty()) return;

        // CRUD/FLS hardening:
        //  - If current user (e.g., integration user) lacks UPDATE on Vehicle__c, exit safely.
        //  - stripInaccessible drops fields the user can't update, preventing exceptions.
        if (!Schema.sObjectType.Vehicle__c.isUpdateable()) return;
        List<SObject> sanitized = Security.stripInaccessible(AccessType.UPDATABLE, updates).getRecords();

        // Chunked DML to respect governor limits on very large PE batches.
        Integer size = sanitized.size();
        for (Integer i = 0; i < size; i += BATCH_SIZE) {
            List<SObject> chunk = new List<SObject>();
            Integer endIdx = Math.min(i + BATCH_SIZE, size);
            for (Integer j = i; j < endIdx; j++) chunk.add(sanitized[j]);
            if (!chunk.isEmpty()) update chunk;
        }

        // ---------- Cache invalidation ----------
        // 1) Bump version: this invalidates ALL prior keys (snapshot + any page key) atomically.
        if (!affectedAccountIds.isEmpty()) {
            bumpVersion(affectedAccountIds);
        }

        // 2) (Optional hygiene) Remove obvious legacy keys for the current version
        //    Not strictly necessary with versioning, but safe to keep.
        try {
            Cache.OrgPartition part = Cache.Org.getPartition(ORG_PARTITION);
            Integer ps = effectivePageSize();
            for (Id aId : affectedAccountIds) {
                String snapKey      = 'acct' + String.valueOf(aId) + 'snapshot';
                String firstPageKey = 'acct' + String.valueOf(aId) + 'ps' + String.valueOf(ps) + 'tokFIRST';
                part.remove(snapKey);
                part.remove(firstPageKey);
            }
        } catch (Exception ignore) {
            // Best-effort only.
        }
    }
}
