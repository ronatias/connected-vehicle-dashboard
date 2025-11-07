trigger VehicleStatusTrigger on Vehicle_Status__e (after insert) {
    VehicleStatusHandler.handleAfterInsert(Trigger.New);
}
