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
    private class PageToken { String v; Id i; }   // last VIN + last Id for keyset pagination

    // ---------- Settings (Custom Metadata: ConnectedVehicleSettings__mdt.Default) ----------
    private static ConnectedVehicleSettings__mdt S() {
        ConnectedVehicleSettings__mdt s = ConnectedVehicleSettings__mdt.getInstance('Default');
        if (s == null) {
            s = new ConnectedVehicleSettings__mdt(
                Use_Mock__c = false, SnapshotThreshold__c = 500,
                PageSize__c = 200, CacheTtlSec__c = 25
            );
        }
        return s;
    }
    private static Integer threshold()       { return (Integer) (S().SnapshotThreshold__c == null ? 500 : S().SnapshotThreshold__c.intValue()); }
    private static Integer pageSizeDefault() { return (Integer) (S().PageSize__c == null ? 200 : S().PageSize__c.intValue()); }
    private static Integer cacheTtl()        { return (Integer) (S().CacheTtlSec__c == null ? 25  : S().CacheTtlSec__c.intValue()); }

    private static final Integer PAGE_SIZE_MAX = 1000;
    private static final String  ORG_PARTITION = 'ConnectedVehicles';

    // ---------- Cache key helpers (MUST be alphanumeric only) ----------
    private static String acctKey(Id accountId) {
        // e.g., acct001XXXXXXXXXXXX
        return 'acct' + String.valueOf(accountId);
    }
    private static String hashToken(String tok) {
        if (String.isBlank(tok)) return 'FIRST';
        Blob d = Crypto.generateDigest('SHA-256', Blob.valueOf(tok));
        return EncodingUtil.convertToHex(d).substring(0, 16); // 0-9a-f
    }
    private static Object cacheGet(String key) {
        try { return Cache.Org.getPartition(ORG_PARTITION).get(key); }
        catch (Exception e) { return null; }
    }
    private static void cachePut(String key, Object value, Integer seconds) {
        try { Cache.Org.getPartition(ORG_PARTITION).put(key, value, seconds); }
        catch (Exception e) { /* best-effort */ }
    }

    // ---------- Public: init (first render) ----------
    @AuraEnabled(cacheable=true)
    public static InitResult initDashboard(Id accountId, Integer pageSizeOpt) {
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
            String cacheKey = acctKey(accountId) + 'snapshot';
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
                : encodeTok(page.get(page.size()-1).VIN__c, page.get(page.size()-1).Id);

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
    public static PageResult getVehiclesPage(Id accountId, Integer pageSizeOpt, String pageTokenB64) {
        if (accountId == null) throw new AuraHandledException('AccountId is required.');
        Integer pageSize = normalizePageSize(pageSizeOpt);

        String cacheKey = acctKey(accountId) + 'ps' + pageSize + 'tok' + hashToken(pageTokenB64);
        PageResult cached = (PageResult) cacheGet(cacheKey);
        if (cached != null) { cached.fromCache = true; return cached; }

        PageToken pt = decodeTok(pageTokenB64);
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
        res.nextToken = encodeTok(page.get(page.size()-1).VIN__c, page.get(page.size()-1).Id);

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

    // ---------- Token helpers ----------
    private static String encodeTok(String lastVin, Id lastId) {
        Map<String, Object> m = new Map<String, Object>{ 'v' => lastVin, 'i' => (String) lastId };
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
            return pt;
        } catch (Exception e) {
            return null;
        }
    }
}
