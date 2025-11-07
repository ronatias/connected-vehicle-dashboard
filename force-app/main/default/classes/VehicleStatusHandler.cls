public with sharing class VehicleStatusHandler {
    @TestVisible private static final Integer BATCH_SIZE = 200;

    public static void handleAfterInsert(List<Vehicle_Status__e> events) {
        if (events == null || events.isEmpty()) return;

        // Collect VINs and (optional) AccountIds from events
        Set<String> vins = new Set<String>();
        Set<String> acctIds = new Set<String>();
        for (Vehicle_Status__e e : events) {
            if (String.isNotBlank(e.VIN__c)) vins.add(e.VIN__c);
            if (String.isNotBlank(e.AccountId__c)) acctIds.add(e.AccountId__c);
        }
        if (vins.isEmpty()) return;

        // Query matching Vehicles (filter by Account if provided)
        List<Vehicle__c> targets;
        if (!acctIds.isEmpty()) {
            targets = [
                SELECT Id, VIN__c, Account__c,
                       FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
                FROM Vehicle__c
                WHERE VIN__c IN :vins AND Account__c IN :acctIds
            ];
        } else {
            targets = [
                SELECT Id, VIN__c, Account__c,
                       FuelLevelPct__c, MileageKm__c, SoftwareVersion__c, LastStatusTs__c
                FROM Vehicle__c
                WHERE VIN__c IN :vins
            ];
        }
        if (targets.isEmpty()) return;

        // Build VIN -> Vehicles map (Apex style; no lambdas)
        Map<String, List<Vehicle__c>> vinToVehicles = new Map<String, List<Vehicle__c>>();
        for (Vehicle__c v : targets) {
            List<Vehicle__c> listForVin = vinToVehicles.get(v.VIN__c);
            if (listForVin == null) {
                listForVin = new List<Vehicle__c>();
                vinToVehicles.put(v.VIN__c, listForVin);
            }
            listForVin.add(v);
        }

        // For each event, prepare an update for the matched vehicle(s)
        List<Vehicle__c> updates = new List<Vehicle__c>();
        for (Vehicle_Status__e e : events) {
            List<Vehicle__c> listForVin = vinToVehicles.get(e.VIN__c);
            if (listForVin == null) continue;

            for (Vehicle__c v : listForVin) {
                Vehicle__c up = new Vehicle__c(Id = v.Id);
                if (e.FuelLevelPct__c != null)   up.FuelLevelPct__c   = Integer.valueOf((Decimal) e.FuelLevelPct__c);
                if (e.MileageKm__c != null)      up.MileageKm__c      = Integer.valueOf((Decimal) e.MileageKm__c);
                if (String.isNotBlank(e.SoftwareVersion__c))
                                                up.SoftwareVersion__c = e.SoftwareVersion__c;
                up.LastStatusTs__c = (e.SourceTs__c == null) ? System.now() : e.SourceTs__c;
                updates.add(up);
            }
        }
        if (updates.isEmpty()) return;

        // CRUD/FLS hardening
        if (!Schema.sObjectType.Vehicle__c.isUpdateable()) return;
        List<SObject> sanitized = Security.stripInaccessible(AccessType.UPDATABLE, updates).getRecords();

        // Chunked DML (no subList usage)
        Integer size = sanitized.size();
        for (Integer i = 0; i < size; i += BATCH_SIZE) {
            List<SObject> chunk = new List<SObject>();
            Integer endIdx = Math.min(i + BATCH_SIZE, size);
            for (Integer j = i; j < endIdx; j++) chunk.add(sanitized[j]);
            if (!chunk.isEmpty()) update chunk;
        }
    }
}
