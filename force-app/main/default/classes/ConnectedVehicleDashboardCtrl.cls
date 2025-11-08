/**
 * ConnectedVehicleDashboardCtrl
 * -----------------------------
 * Purpose
 *  - Serve the Connected Vehicle Dashboard (LWC) with either:
 *      SNAPSHOT mode (<= threshold vehicles) OR
 *      PAGINATED mode (> threshold vehicles with keyset pagination).
 *  - Orchestrate Platform Cache to minimize DB/API calls while keeping data fresh.
 *
 * Design notes
 *  - Uses Custom Metadata (ConnectedVehicleSettings__mdt.Default) for knobs:
 *      - SnapshotThreshold__c: max vehicles for full snapshot
 *      - PageSize__c         : default page size (can be overridden by LWC param)
 *      - CacheTtlSec__c      : org cache TTL (min enforced at 300s to match Org Cache rules)
 *      - Use_Mock__c         : DEMO mode switch (true = read Vehicle__c; false = call Mule)
 *  - Enforces CRUD/FLS on Vehicle__c reads where applicable.
 *  - Keyset pagination (VIN__c, Id) avoids OFFSET limits.
 *
 * Versioned cache keys
 *  - Include a per-Account cache version in cache keys & page tokens.
 *    (Your VehicleStatusHandler can bump/evict snapshot keys on PE updates. Paginated keys expire via TTL.)
 *
 * Nonce-friendly signatures
 *  - @AuraEnabled methods accept String clientNonce. Server ignores it; it exists only to change the
 *    Lightning Data Service storable cache key on demand (e.g., when pressing the LWC Refresh button).
 *
 * Demo vs Real (Use_Mock__c)
 *  - DEMO (true): Snapshot/page rows are built from your current Vehicle__c values (what’s already in org).
 *  - REAL (false): On cache miss, fetch rows from MuleSoft via Named Credential 'Mule_Vehicle_API'
 *    (GET bulk for snapshot, POST by-vins for page). If Mule returns partials, we fall back to Vehicle__c row.
 *
 * Scalability reminders
 *  - Snapshot is capped: LIMIT Math.min(threshold(), 5000) to prevent CPU/heap blowups.
 *  - Paginated path queries small pages (default ~200) with sargable keyset predicates.
 *  - Short TTL cache reduces DB/API hits for hot pages while versioning/eviction keeps data fresh.
 */
public with sharing class ConnectedVehicleDashboardCtrl {

    // ---------- DTOs ----------
    public class VehicleRow {
        @AuraEnabled public String vin;
        @AuraEnabled public Integer fuelLevelPct;
        @AuraEnabled public Integer mileageKm;
        @AuraEnabled public String softwareVersion;
        @AuraEnabled public Datetime sourceTs;
    }
    public class InitResult {
        @AuraEnabled public String mode;          // SNAPSHOT | PAGINATED
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer threshold;
        @AuraEnabled public List<VehicleRow> snapshot; // for SNAPSHOT, or first page for PAGINATED
        @AuraEnabled public String nextToken;     // only for PAGINATED
        @AuraEnabled public Datetime cachedAt;
        @AuraEnabled public Boolean fromCache;
    }
    public class PageResult {
        @AuraEnabled public List<VehicleRow> vehicles;
        @AuraEnabled public String nextToken;
        @AuraEnabled public Datetime cachedAt;
        @AuraEnabled public Boolean fromCache;
    }
    // Version-aware token
    private class PageToken { String v; Id i; Integer ver; }

    // ---------- Settings (Custom Metadata: ConnectedVehicleSettings__mdt.Default) ----------
    private static ConnectedVehicleSettings__mdt S() {
        ConnectedVehicleSettings__mdt s = ConnectedVehicleSettings__mdt.getInstance('Default');
        if (s == null) {
            // Sensible hard defaults for new orgs/demos
            s = new ConnectedVehicleSettings__mdt(
                Use_Mock__c = true,
                SnapshotThreshold__c = 500,
                PageSize__c = 200,
                CacheTtlSec__c = 300
            );
        }
        return s;
    }
    private static Integer threshold()       { return (Integer) (S().SnapshotThreshold__c == null ? 500 : S().SnapshotThreshold__c.intValue()); }
    private static Integer pageSizeDefault() { return (Integer) (S().PageSize__c == null ? 200 : S().PageSize__c.intValue()); }
    private static Integer cacheTtl()        { return (Integer) (S().CacheTtlSec__c == null ? 300 : S().CacheTtlSec__c.intValue()); }
    private static Boolean useMock()         { ConnectedVehicleSettings__mdt s = S(); return (s != null && s.Use_Mock__c == true); }

    private static final Integer PAGE_SIZE_MAX = 1000;

    // ---------- Versioned cache helpers (per-Account) ----------
    private static final String ORG_PARTITION = 'ConnectedVehicles';

    private static String verKey(Id accountId) {
        return 'acct' + String.valueOf(accountId) + ':ver';
    }
    // Read per-account version (default 1 if missing or cache unavailable)
    private static Integer acctVersion(Id accountId) {
        try {
            Cache.OrgPartition p = Cache.Org.getPartition(ORG_PARTITION);
            Object o = p.get(verKey(accountId));
            if (o == null) return 1;
            return (Integer) o;
        } catch (Exception e) {
            return 1;
        }
    }
    // Prefix for all account+version scoped keys, e.g., "acct001...:v3:"
    private static String acctPrefix(Id accountId) {
        return 'acct' + String.valueOf(accountId) + ':v' + String.valueOf(acctVersion(accountId)) + ':';
    }
    private static String snapKey(Id accountId) {
        return acctPrefix(accountId) + 'snapshot';
    }
    private static String pageKey(Id accountId, Integer pageSize, String tokenB64) {
        String tok = String.isBlank(tokenB64) ? 'FIRST' : hashToken(tokenB64);
        return acctPrefix(accountId) + 'ps' + String.valueOf(pageSize) + ':tok' + tok;
    }

    // ---------- Cache accessors (best-effort) ----------
    private static Object cacheGet(String key) {
        try { return Cache.Org.getPartition(ORG_PARTITION).get(key); }
        catch (Exception e) { return null; }
    }
    private static void cachePut(String key, Object value, Integer seconds) {
        try { Cache.Org.getPartition(ORG_PARTITION).put(key, value, Math.max(seconds, 300)); } // enforce 300s min
        catch (Exception e) { /* best-effort */ }
    }

    // ---------- Hash helper ----------
    private static String hashToken(String tok) {
        if (String.isBlank(tok)) return 'FIRST';
        Blob d = Crypto.generateDigest('SHA-256', Blob.valueOf(tok));
        return EncodingUtil.convertToHex(d).substring(0, 16);
    }

    // ---------- Public: init (first render) ----------
    @AuraEnabled(cacheable=true)
    public static InitResult initDashboard(Id accountId, Integer pageSizeOpt, String clientNonce) {
        // clientNonce is intentionally ignored; its presence changes the client storable cache key.
        if (accountId == null) throw new AuraHandledException('AccountId is required.');
        if (!Schema.sObjectType.Vehicle__c.isAccessible())
            throw new AuraHandledException('Access denied.');
        Integer pageSize = normalizePageSize(pageSizeOpt);

        Integer total = [
            SELECT COUNT()
            FROM Vehicle__c
            WHERE Account__c = :accountId AND IsConnected__c = true
        ];

        if (total <= threshold()) {
            // ---------- SNAPSHOT ----------
            String cacheKey = snapKey(accountId);
            InitResult cached = (InitResult) cacheGet(cacheKey);
            if (cached != null) { cached.fromCache = true; return cached; }

            List<VehicleRow> rows;
            if (useMock()) {
                // DEMO: build from existing Vehicle__c (org data)
                List<Vehicle__c> recs = [
                    SELECT VIN__c, FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
                    FROM Vehicle__c
                    WHERE Account__c = :accountId AND IsConnected__c = true
                    ORDER BY VIN__c
                    LIMIT :Math.min(threshold(), 5000) // performance guardrail
                ];
                rows = new List<VehicleRow>();
                for (Vehicle__c v : recs) rows.add(toRow(v));
            } else {
                // REAL: ask Mule for the snapshot (Named Credential: Mule_Vehicle_API)
                rows = fetchSnapshotFromMule(accountId);
                // If Mule returns empty/partial, UI still renders rows=0; PE pipeline persists real-time updates.
            }

            InitResult res = new InitResult();
            res.mode = 'SNAPSHOT';
            res.totalCount = total;
            res.threshold = threshold();
            res.snapshot = rows;
            res.nextToken = null;
            res.cachedAt = System.now();
            res.fromCache = false;

            cachePut(cacheKey, res, cacheTtl());
            return res;

        } else {
            // ---------- PAGINATED (first page) ----------
            PageToken pt = null;
            List<Vehicle__c> page = queryVehiclePage(accountId, pageSize, pt);

            List<VehicleRow> out = new List<VehicleRow>();
            if (useMock()) {
                // DEMO:
                for (Vehicle__c v : page) out.add(toRow(v));
            } else {
                // REAL: get latest statuses for just this page from Mule
                Map<String, VehicleRow> statuses = fetchStatusesByVins(vinsOf(page));
                for (Vehicle__c v : page) {
                    VehicleRow r = statuses.get(v.VIN__c);
                    out.add((r != null) ? r : toRow(v)); // fallback to local if Mule had no entry
                }
            }

            String nextTok = page.isEmpty() ? null
                : encodeTok(page.get(page.size()-1).VIN__c, page.get(page.size()-1).Id, accountId);

            InitResult res = new InitResult();
            res.mode = 'PAGINATED';
            res.totalCount = total;
            res.threshold = threshold();
            res.snapshot = out;     // first page
            res.nextToken = nextTok;
            res.cachedAt = System.now();
            res.fromCache = false;
            return res;
        }
    }

    // ---------- Public: get next page ----------
    @AuraEnabled(cacheable=true)
    public static PageResult getVehiclesPage(Id accountId, Integer pageSizeOpt, String pageTokenB64, String clientNonce) {
        // clientNonce is intentionally ignored; its presence changes the client storable cache key.
        if (accountId == null) throw new AuraHandledException('AccountId is required.');
        Integer pageSize = normalizePageSize(pageSizeOpt);

        // Versioned page key
        String cacheKey = pageKey(accountId, pageSize, pageTokenB64);
        PageResult cached = (PageResult) cacheGet(cacheKey);
        if (cached != null) { cached.fromCache = true; return cached; }

        // Decode token and validate version: tokens from older versions are ignored (restart pagination)
        PageToken pt = decodeTok(pageTokenB64);
        if (pt != null && pt.ver != null && pt.ver != acctVersion(accountId)) {
            pt = null; // force restart (version changed due to updates)
        }

        List<Vehicle__c> page = queryVehiclePage(accountId, pageSize, pt);

        PageResult res = new PageResult();
        res.cachedAt = System.now();
        res.fromCache = false;
        res.vehicles = new List<VehicleRow>();

        if (page.isEmpty()) {
            res.nextToken = null;
            cachePut(cacheKey, res, cacheTtl());
            return res;
        }

        if (useMock()) {
            for (Vehicle__c v : page) res.vehicles.add(toRow(v));
        } else {
            Map<String, VehicleRow> statuses = fetchStatusesByVins(vinsOf(page));
            for (Vehicle__c v : page) {
                VehicleRow r = statuses.get(v.VIN__c);
                res.vehicles.add((r != null) ? r : toRow(v)); // local fallback
            }
        }

        res.nextToken = encodeTok(page.get(page.size()-1).VIN__c, page.get(page.size()-1).Id, accountId);

        cachePut(cacheKey, res, cacheTtl());
        return res;
    }

    // ---------- Helpers ----------
    private static VehicleRow toRow(Vehicle__c v) {
        VehicleRow r = new VehicleRow();
        r.vin = v.VIN__c;
        r.fuelLevelPct = (v.FuelLevelPct__c == null) ? null : ((Decimal) v.FuelLevelPct__c).intValue();
        r.mileageKm = (v.MileageKm__c == null) ? null : ((Decimal) v.MileageKm__c).intValue();
        r.softwareVersion = v.SoftwareVersion__c;
        r.sourceTs = v.LastStatusTs__c;
        return r;
    }

    private static Integer normalizePageSize(Integer p) {
        Integer d = (p == null || p <= 0) ? pageSizeDefault() : p;
        return Math.min(d, PAGE_SIZE_MAX);
    }

    private static Set<String> vinsOf(List<Vehicle__c> recs) {
        Set<String> vins = new Set<String>();
        for (Vehicle__c v : recs) if (String.isNotBlank(v.VIN__c)) vins.add(v.VIN__c);
        return vins;
    }

    private static List<Vehicle__c> queryVehiclePage(Id accountId, Integer size, PageToken pt) {
        if (pt == null) {
            return [
                SELECT Id, VIN__c, FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
                FROM Vehicle__c
                WHERE Account__c = :accountId AND IsConnected__c = true
                ORDER BY VIN__c, Id
                LIMIT :size
            ];
        } else {
            return [
                SELECT Id, VIN__c, FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
                FROM Vehicle__c
                WHERE Account__c = :accountId
                  AND IsConnected__c = true
                  AND (VIN__c > :pt.v OR (VIN__c = :pt.v AND Id > :pt.i))
                ORDER BY VIN__c, Id
                LIMIT :size
            ];
        }
    }

    // ---------- Mule callouts (REAL path via Named Credential) ----------
    // Full snapshot for Account (used only when total <= threshold and cache-miss)
    private static List<VehicleRow> fetchSnapshotFromMule(Id accountId) {
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint('callout:Mule_Vehicle_API/api/vehicle-status/bulk?accountId=' + accountId);
        req.setTimeout(5000);
        Http http = new Http();
        HttpResponse res = http.send(req);
        if (res == null || res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            // Fail-soft: return empty list; UI still renders (may show zero rows until PE updates persist)
            return new List<VehicleRow>();
        }
        List<Object> raw = (List<Object>) System.JSON.deserializeUntyped(res.getBody());
        List<VehicleRow> out = new List<VehicleRow>();
        for (Object o : raw) out.add(mapToRow((Map<String, Object>) o));
        return out;
    }

    // Page statuses for VINs (used in PAGINATED on cache-miss)
    private static Map<String, VehicleRow> fetchStatusesByVins(Set<String> vins) {
        Map<String, VehicleRow> out = new Map<String, VehicleRow>();
        if (vins == null || vins.isEmpty()) return out;

        HttpRequest req = new HttpRequest();
        req.setMethod('POST');
        req.setEndpoint('callout:Mule_Vehicle_API/api/vehicle-status/by-vins');
        req.setHeader('Content-Type','application/json');
        req.setTimeout(5000);
        req.setBody(JSON.serialize(vins));
        Http http = new Http();
        HttpResponse res = http.send(req);
        if (res == null || res.getStatusCode() < 200 || res.getStatusCode() >= 300) return out;

        List<Object> raw = (List<Object>) System.JSON.deserializeUntyped(res.getBody());
        for (Object o : raw) {
            VehicleRow r = mapToRow((Map<String, Object>) o);
            if (String.isNotBlank(r.vin)) out.put(r.vin, r);
        }
        return out;
    }

    // Map raw Mule JSON row → VehicleRow (robust casting)
    private static VehicleRow mapToRow(Map<String, Object> m) {
        VehicleRow r = new VehicleRow();
        r.vin = (String) m.get('vin');
        if (m.containsKey('fuelLevelPct') && m.get('fuelLevelPct') != null)
            r.fuelLevelPct = ((Decimal) m.get('fuelLevelPct')).intValue();
        if (m.containsKey('mileageKm') && m.get('mileageKm') != null)
            r.mileageKm = ((Decimal) m.get('mileageKm')).intValue();
        r.softwareVersion = (String) m.get('softwareVersion');

        // Accept either Datetime or ISO string; if not present, default to now.
        // deserializeUntyped may give DateTime for ISO8601. If not, use System.now().
        Datetime ts = System.now();
        Object rawTs = m.get('ts');
        if (rawTs instanceof Datetime) ts = (Datetime) rawTs;
        r.sourceTs = ts;

        return r;
    }

    // ---------- Token helpers (embed version to avoid cross-version reuse) ----------
    private static String encodeTok(String lastVin, Id lastId, Id accountId) {
        Map<String, Object> m = new Map<String, Object>{
            'v' => lastVin,
            'i' => (String) lastId,
            'ver' => acctVersion(accountId)
        };
        return EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(m)));
    }
    private static PageToken decodeTok(String b64) {
        if (String.isBlank(b64)) return null;
        try {
            String json = EncodingUtil.base64Decode(b64).toString();
            Map<String, Object> m = (Map<String, Object>) System.JSON.deserializeUntyped(json);
            PageToken pt = new PageToken();
            pt.v = (String) m.get('v');
            String idStr = (String) m.get('i');
            pt.i = (idStr == null) ? null : (Id) idStr;
            Object vv = m.get('ver');
            pt.ver = (vv == null) ? null : (Integer) vv;
            return pt;
        } catch (Exception e) {
            return null;
        }
    }
}
