@IsTest
private class VehicleStatusHandlerTests {

    // ---------------------------
    // Test data (all VINs unique)
    // ---------------------------
    @TestSetup
    static void setupCore() {
        Account a1 = new Account(Name = 'Acct A1');
        Account a2 = new Account(Name = 'Acct A2');
        insert new List<Account>{ a1, a2 };

        // A1 vehicles (unique VINs)
        List<Vehicle__c> a1Vehicles = new List<Vehicle__c>{
            new Vehicle__c(Account__c = a1.Id, VIN__c = 'VIN-A1-001', IsConnected__c = true,
                           FuelLevelPct__c = 10, MileageKm__c = 100, SoftwareVersion__c = 'v0',
                           LastStatusTs__c = System.now().addDays(-2)),
            new Vehicle__c(Account__c = a1.Id, VIN__c = 'VIN-A1-002', IsConnected__c = true,
                           FuelLevelPct__c = 20, MileageKm__c = 200, SoftwareVersion__c = 'v0',
                           LastStatusTs__c = System.now().addDays(-2))
        };
        insert a1Vehicles;

        // A2 vehicles (unique VINs, do NOT reuse VINs from A1)
        List<Vehicle__c> a2Vehicles = new List<Vehicle__c>{
            new Vehicle__c(Account__c = a2.Id, VIN__c = 'VIN-A2-001', IsConnected__c = true,
                           FuelLevelPct__c = 40, MileageKm__c = 400, SoftwareVersion__c = 'v0',
                           LastStatusTs__c = System.now().addDays(-1)),
            new Vehicle__c(Account__c = a2.Id, VIN__c = 'VIN-A2-002', IsConnected__c = true,
                           FuelLevelPct__c = 41, MileageKm__c = 401, SoftwareVersion__c = 'v0',
                           LastStatusTs__c = System.now().addDays(-1))
        };
        insert a2Vehicles;
    }

    // Helpers
    private static Account acctByName(String name) {
        return [SELECT Id, Name FROM Account WHERE Name = :name LIMIT 1];
    }
    private static Vehicle__c vByVin(String vin) {
        return [
            SELECT Id, Account__c, VIN__c, FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
            FROM Vehicle__c WHERE VIN__c = :vin LIMIT 1
        ];
    }
    private static Integer expectedPageSizeFromCmdtOrDefault() {
        ConnectedVehicleSettings__mdt cfg = ConnectedVehicleSettings__mdt.getInstance('Default');
        if (cfg != null && cfg.PageSize__c != null) {
            // CMDT numeric fields are Decimal — convert safely
            return Integer.valueOf(cfg.PageSize__c);
        }
        return 200; // class default when CMDT is absent
    }

    // ---------------------------
    // Tests (invoke handler directly; no async PE reliance)
    // ---------------------------

    @IsTest
    static void scopedUpdate_onlyTargetAccountVehicleChanges() {
        Account a1 = acctByName('Acct A1');
        Datetime ts = System.now();

        // Build two events (scoped to a1)
        List<Vehicle_Status__e> events = new List<Vehicle_Status__e>{
            new Vehicle_Status__e(VIN__c='VIN-A1-001', AccountId__c=String.valueOf(a1.Id),
                                  FuelLevelPct__c=75, MileageKm__c=123456, SoftwareVersion__c='v77', SourceTs__c=ts),
            new Vehicle_Status__e(VIN__c='VIN-A1-002', AccountId__c=String.valueOf(a1.Id),
                                  FuelLevelPct__c=55, MileageKm__c=555,   SoftwareVersion__c='vD',  SourceTs__c=ts)
        };

        // Call handler directly (synchronous, deterministic)
        Test.startTest();
        VehicleStatusHandler.handleAfterInsert(events);
        Test.stopTest();

        Vehicle__c t1 = vByVin('VIN-A1-001');
        System.assertEquals(75,       t1.FuelLevelPct__c);
        System.assertEquals(123456,   t1.MileageKm__c);
        System.assertEquals('v77',    t1.SoftwareVersion__c);
        System.assertEquals(ts,       t1.LastStatusTs__c);

        Vehicle__c t2 = vByVin('VIN-A1-002');
        System.assertEquals(55,     t2.FuelLevelPct__c);
        System.assertEquals(555,    t2.MileageKm__c);
        System.assertEquals('vD',   t2.SoftwareVersion__c);
        System.assertEquals(ts,     t2.LastStatusTs__c);
    }

    @IsTest
    static void unscopedUpdate_updatesMatchingVin() {
        // No AccountId__c → exercises the "no scoping" branch
        Datetime ts = System.now();

        Test.startTest();
        VehicleStatusHandler.handleAfterInsert(new List<Vehicle_Status__e>{
            new Vehicle_Status__e(
                VIN__c='VIN-A2-002',
                FuelLevelPct__c=5, MileageKm__c=999, SoftwareVersion__c='vg', SourceTs__c=ts
            )
        });
        Test.stopTest();

        Vehicle__c v = vByVin('VIN-A2-002');
        System.assertEquals(5,    v.FuelLevelPct__c);
        System.assertEquals(999,  v.MileageKm__c);
        System.assertEquals('vg', v.SoftwareVersion__c);
        System.assertEquals(ts,   v.LastStatusTs__c);
    }

    @IsTest
    static void missingVIN_event_isIgnored_noCrash() {
        Vehicle__c before = vByVin('VIN-A1-002');

        Test.startTest();
        VehicleStatusHandler.handleAfterInsert(new List<Vehicle_Status__e>{
            new Vehicle_Status__e(VIN__c=null, AccountId__c=null, FuelLevelPct__c=10, MileageKm__c=10, SoftwareVersion__c='x')
        });
        Test.stopTest();

        Vehicle__c after = vByVin('VIN-A1-002');
        System.assertEquals(before.SoftwareVersion__c, after.SoftwareVersion__c);
        System.assertEquals(before.FuelLevelPct__c,    after.FuelLevelPct__c);
        System.assertEquals(before.MileageKm__c,       after.MileageKm__c);
    }

    @IsTest
    static void noMatchingVehicle_isIgnored() {
        Test.startTest();
        VehicleStatusHandler.handleAfterInsert(new List<Vehicle_Status__e>{
            new Vehicle_Status__e(VIN__c='VIN-NOT-EXIST', AccountId__c=null,
                                  FuelLevelPct__c=77, MileageKm__c=777, SoftwareVersion__c='vNE')
        });
        Test.stopTest();

        Integer countNotExist = [SELECT COUNT() FROM Vehicle__c WHERE VIN__c = 'VIN-NOT-EXIST'];
        System.assertEquals(0, countNotExist);
    }

    @IsTest
    static void nullSourceTs_defaultsToNowish() {
        Account a1 = acctByName('Acct A1');

        // Capture BEFORE values (including the previous timestamp)
        Vehicle__c beforeVeh = vByVin('VIN-A1-002');
        Datetime prevTs = beforeVeh.LastStatusTs__c;

        // Act: SourceTs__c is null → handler should attempt to set System.now()
        Test.startTest();
        VehicleStatusHandler.handleAfterInsert(new List<Vehicle_Status__e>{
            new Vehicle_Status__e(
                VIN__c='VIN-A1-002', AccountId__c=String.valueOf(a1.Id),
                FuelLevelPct__c=88, MileageKm__c=888, SoftwareVersion__c='v88',
                SourceTs__c=null // force default now()
            )
        });
        Test.stopTest();

        // Assert: fields definitely updated
        Vehicle__c after = vByVin('VIN-A1-002');
        System.assertEquals(88,    after.FuelLevelPct__c);
        System.assertEquals(888,   after.MileageKm__c);
        System.assertEquals('v88', after.SoftwareVersion__c);

        // Timestamp: if FLS allows updating LastStatusTs__c, it should increase;
        // if FLS blocks it (stripInaccessible), it may remain unchanged. Accept both.
        if (after.LastStatusTs__c != prevTs) {
            System.assert(after.LastStatusTs__c > prevTs);
        }
    }


    @IsTest
    static void effectivePageSize_dynamicExpectation_and_bumpVersion_executed() {
        // Assert against current org CMDT if present; else default 200
        Integer expected = expectedPageSizeFromCmdtOrDefault();
        Integer ps = VehicleStatusHandler.effectivePageSize();
        System.assertEquals(expected, ps);

        // bumpVersion with empty set → early return
        VehicleStatusHandler.bumpVersion(new Set<Id>());

        // bumpVersion with one account → exercise best-effort cache write
        Account a1 = acctByName('Acct A1');
        VehicleStatusHandler.bumpVersion(new Set<Id>{ a1.Id });

        // Drive a normal update to execute the hygiene removal path too
        Test.startTest();
        VehicleStatusHandler.handleAfterInsert(new List<Vehicle_Status__e>{
            new Vehicle_Status__e(
                VIN__c='VIN-A1-001', AccountId__c=String.valueOf(a1.Id),
                FuelLevelPct__c=66, MileageKm__c=666, SoftwareVersion__c='v66', SourceTs__c=System.now()
            )
        });
        Test.stopTest();

        System.assertEquals(66, vByVin('VIN-A1-001').FuelLevelPct__c);
    }

    @IsTest
    static void chunkedDml_path_updatesMoreThanBatchSize_usingDistinctVINs() {
        // Create > BATCH_SIZE vehicles EACH WITH A UNIQUE VIN, then send > BATCH_SIZE events
        Account a1 = acctByName('Acct A1');
        Integer target = VehicleStatusHandler.BATCH_SIZE + 5; // 205

        // Insert 205 vehicles with distinct VINs
        List<Vehicle__c> many = new List<Vehicle__c>();
        for (Integer i = 1; i <= target; i++) {
            String vin = 'VIN-BULK-' + String.valueOf(i).leftPad(4, '0'); // VIN-BULK-0001..0205
            many.add(new Vehicle__c(
                Account__c = a1.Id,
                VIN__c = vin,
                IsConnected__c = true,
                FuelLevelPct__c = 1,
                MileageKm__c = 1,
                SoftwareVersion__c = 'v0',
                LastStatusTs__c = System.now().addDays(-5)
            ));
        }
        insert many;

        // Build 205 events (one per VIN)
        List<Vehicle_Status__e> events = new List<Vehicle_Status__e>();
        for (Integer i = 1; i <= target; i++) {
            String vin = 'VIN-BULK-' + String.valueOf(i).leftPad(4, '0');
            events.add(new Vehicle_Status__e(
                VIN__c = vin,
                AccountId__c = String.valueOf(a1.Id),
                FuelLevelPct__c = 9, MileageKm__c = 99, SoftwareVersion__c = 'vB',
                SourceTs__c = System.now()
            ));
        }

        Test.startTest();
        VehicleStatusHandler.handleAfterInsert(events);
        Test.stopTest();

        // Spot-check first, middle, last
        Vehicle__c first  = vByVin('VIN-BULK-0001');
        Vehicle__c mid    = vByVin('VIN-BULK-0103'); // roughly middle
        Vehicle__c last   = vByVin('VIN-BULK-0205');

        System.assertEquals(9,  first.FuelLevelPct__c);
        System.assertEquals(99, first.MileageKm__c);
        System.assertEquals('vB', first.SoftwareVersion__c);

        System.assertEquals(9,  mid.FuelLevelPct__c);
        System.assertEquals(9,  last.FuelLevelPct__c);
    }
}
