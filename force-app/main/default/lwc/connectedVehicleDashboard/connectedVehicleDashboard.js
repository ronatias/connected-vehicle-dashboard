import { LightningElement, api, track } from 'lwc';
import initDashboard from '@salesforce/apex/ConnectedVehicleDashboardCtrl.initDashboard';
import getVehiclesPage from '@salesforce/apex/ConnectedVehicleDashboardCtrl.getVehiclesPage';
import { subscribe, onError, isEmpEnabled } from 'lightning/empApi';

export default class ConnectedVehicleDashboard extends LightningElement {
  @api recordId;

  @track rows = [];
  @track isLoadingInitial = true;
  @track isLoadingMore = false;
  @track cachedAt;
  @track fromCache = false;

  isPaginated = false;
  nextToken = null;
  noMoreData = false;
  totalCount = 0;

  get loadedCount() { return this.rows?.length ?? 0; }

  columns = [
    { label: 'VIN', fieldName: 'vin',
      cellAttributes: { alignment: 'left' } },
  
    { label: 'Fuel (%)', fieldName: 'fuelLevelPct', type: 'number',
      cellAttributes: { alignment: 'left' } },
  
    { label: 'Mileage (km)', fieldName: 'mileageKm', type: 'number',
      cellAttributes: { alignment: 'left' } },
  
    { label: 'Software Version', fieldName: 'softwareVersion',
      cellAttributes: { alignment: 'left' } },
  
    { label: 'Updated', fieldName: 'sourceTs', type: 'date',
      typeAttributes: { year:'numeric', month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit' },
      cellAttributes: { alignment: 'left' } },
  ];
  

  channelName = '/event/Vehicle_Status__e';
  subscription;

  connectedCallback() {
    this.init();
    this.subscribeEvents();
  }

  get disableRefresh() {
    return this.isLoadingInitial;
  }
  get disableLoadMore() {
    return this.noMoreData || this.isLoadingMore || !this.isPaginated;
  }

  get showSpinner() {
    return this.isLoadingInitial || this.isLoadingMore;
  }

  get spinnerText() {
    return this.isLoadingMore ? 'Loading more vehicles…' : 'Loading vehicles…';
  }

  async init() {
    this.isLoadingInitial = true;
    this.rows = [];
    this.noMoreData = false;
    this.nextToken = null;

    try {
      const res = await initDashboard({ accountId: this.recordId, pageSizeOpt: null, clientNonce: Date.now().toString()});
      this.totalCount = res?.totalCount ?? 0;
      this.cachedAt   = res?.cachedAt;
      this.fromCache  = !!res?.fromCache;

      if (res?.mode === 'SNAPSHOT') {
        this.isPaginated = false;
        this.rows = res?.snapshot ?? [];
        this.noMoreData = true; // nothing to paginate
      } else {
        this.isPaginated = true;
        this.rows = res?.snapshot ?? [];
        this.nextToken = res?.nextToken || null;
        this.noMoreData = !this.nextToken;
      }
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error('initDashboard error', e);
    } finally {
      this.isLoadingInitial = false;
    }
  }

  async handleLoadMore() {
    if (!this.isPaginated || this.noMoreData || this.isLoadingMore) return;
    if (!this.nextToken) { this.noMoreData = true; return; }

    this.isLoadingMore = true;
    try {
      const res = await getVehiclesPage({ accountId: this.recordId, pageSizeOpt: null, pageTokenB64: this.nextToken, clientNonce: Date.now().toString() });      const more = res?.vehicles ?? [];
      // append
      this.rows = this.rows.concat(more);
      // advance
      this.nextToken = res?.nextToken || null;
      this.cachedAt  = res?.cachedAt;
      this.fromCache = !!res?.fromCache;
      if (!this.nextToken) this.noMoreData = true;
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error('getVehiclesPage error', e);
    } finally {
      this.isLoadingMore = false;
    }
  }

  handleRefresh() { 
    this.init(); 
}

  subscribeEvents() {
    if (!isEmpEnabled) return;
    const replayId = -1;
    const callback = (msg) => {
      const p = msg?.data?.payload;
      if (!p || p.AccountId__c !== this.recordId) return;

      const idx = this.rows.findIndex(r => r.vin === p.VIN__c);
      const updated = {
        vin: p.VIN__c,
        fuelLevelPct: p.FuelLevelPct__c,
        mileageKm: p.MileageKm__c,
        softwareVersion: p.SoftwareVersion__c,
        sourceTs: p.SourceTs__c
      };
      if (idx >= 0) {
        const clone = [...this.rows];
        clone[idx] = { ...clone[idx], ...updated };
        this.rows = clone;
      }
    };
    subscribe(this.channelName, replayId, callback).then(sub => { this.subscription = sub; });
    onError((e) => console.error('EMP error', e)); // eslint-disable-line no-console
  }
}
