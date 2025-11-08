@IsTest
private class ConnectedVehicleDashboardCtrlTests {

    // -----------------------------
    // Utilities
    // -----------------------------

    // Detect if Platform Cache partition 'ConnectedVehicles' is usable.
    private static Boolean isCacheAvailable() {
        try {
            Cache.OrgPartition p = Cache.Org.getPartition('ConnectedVehicles');
            if (p == null) return false;
            String key = 'ut_cache_probe_' + String.valueOf(Crypto.getRandomLong());
            p.put(key, 'ok', 60);
            Object got = p.get(key);
            return got != null && String.valueOf(got) == 'ok';
        } catch (Exception e) {
            return false;
        }
    }

    private static Account getAcct() {
        return [SELECT Id, Name FROM Account WHERE Name = 'Champion Motors Test' LIMIT 1];
    }

    // -----------------------------
    // Seed data
    // -----------------------------
    @TestSetup
    static void setupData() {
        Account a = new Account(Name = 'Champion Motors Test');
        insert a;

        // Deterministic VINs: V0001..V0010
        List<Vehicle__c> vs = new List<Vehicle__c>();
        for (Integer i = 1; i <= 10; i++) {
            String vin = 'V' + String.valueOf(10000 + i).substring(1);
            vs.add(new Vehicle__c(
                Account__c         = a.Id,
                IsConnected__c     = true,
                VIN__c             = vin,
                FuelLevelPct__c    = 50 + i,
                MileageKm__c       = 10000 + 100*i,
                SoftwareVersion__c = 'v1.' + i,
                LastStatusTs__c    = System.now().addMinutes(-i)
            ));
        }
        insert vs;
    }

    // -----------------------------
    // Tests
    // -----------------------------

    @IsTest
    static void snapshot_init_buildsRows_and_optionallyCaches() {
        Account a = getAcct();
        Boolean cacheOk = isCacheAvailable();

        // First call: snapshot mode (10 <= threshold 500)
        ConnectedVehicleDashboardCtrl.InitResult first =
            ConnectedVehicleDashboardCtrl.initDashboard(a.Id, 3, 'nonce1');

        System.assertEquals('SNAPSHOT', first.mode);
        System.assertEquals(10, first.totalCount);
        System.assertNotEquals(null, first.snapshot);
        System.assertEquals(10, first.snapshot.size());
        System.assertEquals(false, first.fromCache);

        // Second call: hit cache only if cache available
        ConnectedVehicleDashboardCtrl.InitResult second =
            ConnectedVehicleDashboardCtrl.initDashboard(a.Id, 3, 'nonce2');

        System.assertEquals('SNAPSHOT', second.mode);
        System.assertNotEquals(null, second.cachedAt);
        System.assertEquals('V0001', second.snapshot[0].vin);
        System.assertEquals('V0010', second.snapshot[9].vin);

        if (cacheOk) {
            System.assertEquals(true, second.fromCache);
        } else {
            System.assertEquals(false, second.fromCache);
        }
    }

    @IsTest
    static void pagination_firstPage_then_repeat_sameInput() {
        Account a = getAcct();
        Boolean cacheOk = isCacheAvailable();

        Integer pageSize = 3;

        // FIRST page (no token)
        ConnectedVehicleDashboardCtrl.PageResult p1 =
            ConnectedVehicleDashboardCtrl.getVehiclesPage(a.Id, pageSize, null, 'x1');

        System.assertNotEquals(null, p1);
        System.assertEquals(3, p1.vehicles.size());
        System.assertEquals('V0001', p1.vehicles[0].vin);
        System.assertNotEquals(null, p1.nextToken);
        System.assertEquals(false, p1.fromCache);

        // Same inputs again (null token)
        ConnectedVehicleDashboardCtrl.PageResult p1Again =
            ConnectedVehicleDashboardCtrl.getVehiclesPage(a.Id, pageSize, null, 'x2');

        System.assertEquals(3, p1Again.vehicles.size());
        System.assertEquals('V0001', p1Again.vehicles[0].vin);

        if (cacheOk) {
            System.assertEquals(true, p1Again.fromCache);
        } else {
            System.assertEquals(false, p1Again.fromCache);
        }
    }

    @IsTest
    static void pagination_keyset_allPages_and_emptyAfterLast() {
        Account a = getAcct();
        Integer pageSize = 4;

        // Page 1
        ConnectedVehicleDashboardCtrl.PageResult p1 =
            ConnectedVehicleDashboardCtrl.getVehiclesPage(a.Id, pageSize, null, 'y1');
        System.assertEquals(4, p1.vehicles.size());
        System.assertEquals('V0001', p1.vehicles[0].vin);
        System.assertEquals('V0004', p1.vehicles[3].vin);
        System.assertNotEquals(null, p1.nextToken);

        // Page 2
        ConnectedVehicleDashboardCtrl.PageResult p2 =
            ConnectedVehicleDashboardCtrl.getVehiclesPage(a.Id, pageSize, p1.nextToken, 'y2');
        System.assertEquals(4, p2.vehicles.size());
        System.assertEquals('V0005', p2.vehicles[0].vin);
        System.assertEquals('V0008', p2.vehicles[3].vin);
        System.assertNotEquals(null, p2.nextToken);

        // Page 3 (last page has 2 rows) — token will STILL be non-null per controller design
        ConnectedVehicleDashboardCtrl.PageResult p3 =
            ConnectedVehicleDashboardCtrl.getVehiclesPage(a.Id, pageSize, p2.nextToken, 'y3');
        System.assertEquals(2, p3.vehicles.size());
        System.assertEquals('V0009', p3.vehicles[0].vin);
        System.assertEquals('V0010', p3.vehicles[1].vin);
        System.assertNotEquals(null, p3.nextToken, 'Controller returns a token even on the last non-empty page.');

        // One more call with p3 token → EMPTY page and nextToken == null
        ConnectedVehicleDashboardCtrl.PageResult p4Empty =
            ConnectedVehicleDashboardCtrl.getVehiclesPage(a.Id, pageSize, p3.nextToken, 'y4');
        System.assertEquals(0, p4Empty.vehicles.size(), 'After last page, next call should be empty.');
        System.assertEquals(null, p4Empty.nextToken, 'Empty page returns null nextToken.');
    }

    @IsTest
    static void versionBump_ifCacheExists_restartsPagination_otherwise_continues() {
        Account a = getAcct();
        Boolean cacheOk = isCacheAvailable();
        Integer pageSize = 3;

        ConnectedVehicleDashboardCtrl.PageResult p1 =
            ConnectedVehicleDashboardCtrl.getVehiclesPage(a.Id, pageSize, null, 'z1');
        String oldToken = p1.nextToken;
        System.assertNotEquals(null, oldToken);

        // Bump cache version (only meaningful if cache is available)
        if (cacheOk) {
            try {
                Cache.OrgPartition part = Cache.Org.getPartition('ConnectedVehicles');
                Object curr = part.get('acct' + String.valueOf(a.Id) + ':ver');
                Integer nextVer = (curr == null) ? 2 : ((Integer) curr) + 1;
                part.put('acct' + String.valueOf(a.Id) + ':ver', nextVer, 86400);
            } catch (Exception ignore) {}
        }

        ConnectedVehicleDashboardCtrl.PageResult next =
            ConnectedVehicleDashboardCtrl.getVehiclesPage(a.Id, pageSize, oldToken, 'z2');

        System.assertEquals(3, next.vehicles.size());

        if (cacheOk) {
            // Old token rejected (version changed) → restart at first page
            System.assertEquals('V0001', next.vehicles[0].vin);
        } else {
            // Without cache (version fixed at 1), token remains valid → continue to next page
            System.assertEquals('V0004', next.vehicles[0].vin);
        }
    }
}
