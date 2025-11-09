/**
 * Purpose:
 *  - Displays real-time connected vehicle data for an Account.
 *  - Fetches data via Apex (ConnectedVehicleDashboardCtrl) with pagination and caching.
 *  - Subscribes to Vehicle_Status__e Platform Event via EMP API for live updates.
 *
 * Developer Notes:
 *  - initDashboard() → initial load (snapshot or paginated first page)
 *  - getVehiclesPage() → fetch next page
 *  - EMP subscription keeps rows up to date when Platform Events arrive.
 *  - Spinner appears while loading or fetching more rows.
 *  - Optimized for 50k+ concurrent users through Platform Cache + event-driven design.
 */

import { LightningElement, api, track } from 'lwc';
import initDashboard from '@salesforce/apex/ConnectedVehicleDashboardCtrl.initDashboard';
import getVehiclesPage from '@salesforce/apex/ConnectedVehicleDashboardCtrl.getVehiclesPage';
import { subscribe, onError, isEmpEnabled } from 'lightning/empApi';

export default class ConnectedVehicleDashboard extends LightningElement {
  // Account Id (injected by record page)
  @api recordId;

  // Reactive tracked data and flags
  @track rows = [];              // visible vehicle rows
  @track isLoadingInitial = true; // true while initial data load in progress
  @track isLoadingMore = false;   // true while pagination in progress
  @track cachedAt;                // timestamp from Apex response
  @track fromCache = false;       // indicates if result came from Platform Cache

  // Internal state
  isPaginated = false;  // determines whether pagination is enabled
  nextToken = null;     // pagination token (for next page)
  noMoreData = false;   // true if all vehicles loaded
  totalCount = 0;       // total vehicles available

  // Computed getter: dynamically returns number of rows loaded
  get loadedCount() { return this.rows?.length ?? 0; }

  // DataTable column definitions
  columns = [
    { label: 'VIN', fieldName: 'vin', cellAttributes: { alignment: 'left' } },
    { label: 'Fuel (%)', fieldName: 'fuelLevelPct', type: 'number', cellAttributes: { alignment: 'left' } },
    { label: 'Mileage (km)', fieldName: 'mileageKm', type: 'number', cellAttributes: { alignment: 'left' } },
    { label: 'Software Version', fieldName: 'softwareVersion', cellAttributes: { alignment: 'left' } },
    { 
      label: 'Updated',
      fieldName: 'sourceTs',
      type: 'date',
      typeAttributes: { year:'numeric', month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit' },
      cellAttributes: { alignment: 'left' }
    },
  ];

  // Platform Event channel for live updates
  channelName = '/event/Vehicle_Status__e';
  subscription; // holds EMP API subscription handle

  // --------------------------
  // Lifecycle
  // --------------------------
  connectedCallback() {
    // Load initial data and subscribe for event-driven updates
    this.init();
    this.subscribeEvents();
  }

  // --------------------------
  // UI State Getters
  // --------------------------
  get disableRefresh() {
    // Disable Refresh button while initial loading
    return this.isLoadingInitial;
  }
  get disableLoadMore() {
    // Disable Load More button if:
    //  - all data loaded
    //  - currently fetching more
    //  - or dashboard is not in paginated mode
    return this.noMoreData || this.isLoadingMore || !this.isPaginated;
  }

  // Unified spinner control for both load types
  get showSpinner() {
    return this.isLoadingInitial || this.isLoadingMore;
  }

  // Text displayed under spinner
  get spinnerText() {
    return this.isLoadingMore ? 'Loading more vehicles…' : 'Loading vehicles…';
  }

  // --------------------------
  // Initialization logic
  // --------------------------
  async init() {
    // Resets state and loads snapshot or first page
    this.isLoadingInitial = true;
    this.rows = [];
    this.noMoreData = false;
    this.nextToken = null;

    try {
      const res = await initDashboard({
        accountId: this.recordId,
        pageSizeOpt: null,
        clientNonce: Date.now().toString() // used to bust client-side storable cache
      });

      // Assign result properties safely using null coalescing
      this.totalCount = res?.totalCount ?? 0;
      this.cachedAt   = res?.cachedAt;
      this.fromCache  = !!res?.fromCache;

      // Determine mode: snapshot (single payload) vs paginated
      if (res?.mode === 'SNAPSHOT') {
        this.isPaginated = false;
        this.rows = res?.snapshot ?? [];
        this.noMoreData = true; // single-page view, no pagination needed
      } else {
        this.isPaginated = true;
        this.rows = res?.snapshot ?? [];
        this.nextToken = res?.nextToken || null;
        this.noMoreData = !this.nextToken;
      }
    } catch (e) {
      // Log Apex call errors (common causes: recordId null, FLS/CRUD enforcement)
      // eslint-disable-next-line no-console
      console.error('initDashboard error', e);
    } finally {
      // Always release spinner state
      this.isLoadingInitial = false;
    }
  }

  // --------------------------
  // Pagination: Load More
  // --------------------------
  async handleLoadMore() {
    // Defensive: stop if invalid conditions
    if (!this.isPaginated || this.noMoreData || this.isLoadingMore) return;
    if (!this.nextToken) { this.noMoreData = true; return; }

    this.isLoadingMore = true;
    try {
      const res = await getVehiclesPage({
        accountId: this.recordId,
        pageSizeOpt: null,
        pageTokenB64: this.nextToken,
        clientNonce: Date.now().toString()
      });

      const more = res?.vehicles ?? [];
      // Append new rows to the existing dataset
      this.rows = this.rows.concat(more);

      // Update state after pagination response
      this.nextToken = res?.nextToken || null;
      this.cachedAt  = res?.cachedAt;
      this.fromCache = !!res?.fromCache;

      // If no further token returned → reached the end
      if (!this.nextToken) this.noMoreData = true;
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error('getVehiclesPage error', e);
    } finally {
      this.isLoadingMore = false;
    }
  }

  // --------------------------
  // Refresh Button Handler
  // --------------------------
  handleRefresh() {
    // Clears UI and re-fetches data
    this.init();
  }

  // --------------------------
  // EMP API Subscription
  // --------------------------
  subscribeEvents() {
    if (!isEmpEnabled) return; // skip if EMP is disabled in org

    const replayId = -1; // start from newest event
    const callback = (msg) => {
      const p = msg?.data?.payload;
      if (!p || p.AccountId__c !== this.recordId) return; // ignore events for other Accounts

      // Build updated row data from event payload
      const idx = this.rows.findIndex(r => r.vin === p.VIN__c);
      const updated = {
        vin: p.VIN__c,
        fuelLevelPct: p.FuelLevelPct__c,
        mileageKm: p.MileageKm__c,
        softwareVersion: p.SoftwareVersion__c,
        sourceTs: p.SourceTs__c
      };

      // If vehicle exists in the current table, update its row
      if (idx >= 0) {
        const clone = [...this.rows]; // clone array for reactivity
        clone[idx] = { ...clone[idx], ...updated };
        this.rows = clone;
      }
    };

    // Subscribe to platform event channel
    subscribe(this.channelName, replayId, callback)
      .then(sub => { this.subscription = sub; });

    // Log EMP-level connection errors
    onError((e) => console.error('EMP error', e)); // eslint-disable-line no-console
  }
}
