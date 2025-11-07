/**
 * ConnectedVehicleDashboardCtrl
 * -----------------------------
 * Purpose
 *  - Serve the Connected Vehicle Dashboard (LWC) with either:
 *      SNAPSHOT mode (<= threshold vehicles) OR
 *      PAGINATED mode (> threshold vehicles with keyset pagination).
 *  - Orchestrate Platform Cache to minimize DB/API calls while keeping data fresh.
 *
 * Design notes (unchanged)
 *  - Uses Custom Metadata (ConnectedVehicleSettings__mdt.Default) for knobs:
 *      - SnapshotThreshold__c: max vehicles for full snapshot
 *      - PageSize__c         : default page size (can be overridden by LWC param)
 *      - CacheTtlSec__c      : org cache TTL
 *      - Use_Mock__c         : (demo-only) bypass external callouts
 *  - Enforces CRUD/FLS on Vehicle__c reads where applicable.
 *  - Keyset pagination (VIN__c, Id) avoids OFFSET limits.
 *
 * NEW (2025-11-07): Versioned cache keys
 *  - Introduce a per-Account cache version and include it in ALL cache keys & page tokens.
 *    Handler bumps the version on PE updates → invalidates prior cache keys.
 *
 * NEW: Nonce-friendly signatures
 *  - @AuraEnabled methods now accept String clientNonce.
 *  - Server ignores the value; it only busts the client storable cache key.
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
    // version-aware token
    private class PageToken { String v; Id i; Integer ver; }

    // ---------- Settings (Custom Metadata: ConnectedVehicleSettings__mdt.Default) ----------
    private static ConnectedVehicleSettings__mdt S() {
        ConnectedVehicleSettings__mdt s = ConnectedVehicleSettings__mdt.getInstance('Default');
        if (s == null) {
            s = new ConnectedVehicleSettings__mdt(
                Use_Mock__c = false, SnapshotThreshold__c = 500,
                PageSize__c = 200, CacheTtlSec__c = 300
            );
        }
        return s;
    }
    private static Integer threshold()       { return (Integer) (S().SnapshotThreshold__c == null ? 500 : S().SnapshotThreshold__c.intValue()); }
    private static Integer pageSizeDefault() { return (Integer) (S().PageSize__c == null ? 200 : S().PageSize__c.intValue()); }
    private static Integer cacheTtl()        { return (Integer) (S().CacheTtlSec__c == null ? 300 : S().CacheTtlSec__c.intValue()); }

    private static final Integer PAGE_SIZE_MAX = 1000;

    // ---------- Versioned cache helpers (per-Account) ----------
    private static final String ORG_PARTITION = 'ConnectedVehicles';

    private static String verKey(Id accountId) {
        return 'acct' + String.valueOf(accountId) + ':ver';
    }
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
        try { Cache.Org.getPartition(ORG_PARTITION).put(key, value, Math.max(seconds, 300)); }
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
            // SNAPSHOT: read telemetry directly from Vehicle__c, then cache
            String cacheKey = snapKey(accountId);
            InitResult cached = (InitResult) cacheGet(cacheKey);
            if (cached != null) { cached.fromCache = true; return cached; }

            List<Vehicle__c> recs = [
                SELECT VIN__c, FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
                FROM Vehicle__c
                WHERE Account__c = :accountId AND IsConnected__c = true
                ORDER BY VIN__c
                LIMIT :Math.min(threshold(), 5000)
            ];

            List<VehicleRow> rows = new List<VehicleRow>();
            for (Vehicle__c v : recs) rows.add(toRow(v));

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
            // PAGINATED: first page from DB
            PageToken pt = null;
            List<Vehicle__c> page = queryVehiclePage(accountId, pageSize, pt);

            List<VehicleRow> out = new List<VehicleRow>();
            for (Vehicle__c v : page) out.add(toRow(v));

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

        String cacheKey = pageKey(accountId, pageSize, pageTokenB64);
        PageResult cached = (PageResult) cacheGet(cacheKey);
        if (cached != null) { cached.fromCache = true; return cached; }

        PageToken pt = decodeTok(pageTokenB64);
        if (pt != null && pt.ver != null && pt.ver != acctVersion(accountId)) {
            pt = null; // force restart
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

        for (Vehicle__c v : page) res.vehicles.add(toRow(v));
        res.nextToken = encodeTok(page.get(page.size()-1).VIN__c, page.get(page.size()-1).Id, accountId);

        cachePut(cacheKey, res, cacheTtl());
        return res;
    }

    // ---------- Helpers ----------
    private static VehicleRow toRow(Vehicle__c v) {
        VehicleRow r = new VehicleRow();
        r.vin = v.VIN__c;
        r.fuelLevelPct = (Integer) v.FuelLevelPct__c;
        r.mileageKm = (Integer) v.MileageKm__c;
        r.softwareVersion = v.SoftwareVersion__c;
        r.sourceTs = v.LastStatusTs__c;
        return r;
    }

    private static Integer normalizePageSize(Integer p) {
        Integer d = (p == null || p <= 0) ? pageSizeDefault() : p;
        return Math.min(d, PAGE_SIZE_MAX);
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
