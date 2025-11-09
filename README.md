# 🚗 Connected Vehicle Dashboard

### Real-Time Telemetry Visualization for Champion Motors

The **Connected Vehicle Dashboard** is a Salesforce-based solution designed to display and manage live vehicle telemetry data — including **fuel level**, **mileage**, and **software version** — for all connected vehicles owned by a customer.  
It integrates with **MuleSoft APIs** and **Salesforce Platform Events** to deliver **real-time updates**, **optimized caching**, and **scalable performance** across tens of thousands of concurrent users.

---

## ✨ Key Features
- **Real-Time Updates:**  
  Vehicle data is automatically refreshed via **Platform Events** (`Vehicle_Status__e`) without page reloads.

- **Hybrid Caching Strategy:**  
  Uses **Platform Cache** for per-account caching, minimizing redundant API calls while keeping data fresh.

- **Snapshot & Pagination Modes:**  
  Automatically switches between full-snapshot and keyset-pagination modes based on the number of vehicles per account.

- **EMP API Integration:**  
  The LWC subscribes to `/event/Vehicle_Status__e` for instant row-level UI updates.

- **Scalable Architecture:**  
  Bulk-safe Apex logic, TTL-based cache expiration, and account-level versioning ensure efficiency at scale.

- **Configurable Behavior:**  
  All thresholds and cache settings are managed via **Custom Metadata Type** (`ConnectedVehicleSettings__mdt`).

---

## 📄 Documentation

### 📘 [Connected Vehicle Dashboard – Technical Design Document](https://docs.google.com/document/d/124wvWIvtMQWgmVvuC3-MrDPNAi85fytG6iMkkdtiXEs/edit?usp=sharing)
Comprehensive architecture and design explanation covering:
- Data flow  
- Platform Event integration  
- Cache and performance strategy  
- Scalability and governance model  
*(Author: Ronen Atias-Koliran)*

---

### 🧭 [Connected Vehicle Dashboard – Demo Operation Guide](https://docs.google.com/document/d/1-ZXMuu3Rw8nAW-uhfJWRnJ2Gn9D9ib23nVTkCnAQHfw/edit?usp=sharing)
Step-by-step demo instructions for operating the Connected Vehicle Dashboard, including:
- Login details for the demo org  
- How to access and run the dashboard  
- Platform Event test script for live updates  
- How to experiment with snapshot/pagination modes  

---

## 🧩 Components Overview

| Layer | Component | Purpose |
|--------|------------|----------|
| **UI Layer** | `connectedVehicleDashboard` (LWC) | Displays live telemetry and handles real-time updates |
| **Service Layer** | `ConnectedVehicleDashboardCtrl` (Apex) | Serves data, caching, pagination logic |
| **Integration Layer** | `Vehicle_Status__e` | Receives telemetry from MuleSoft |
| **Handler Layer** | `VehicleStatusHandler` | Processes Platform Events and updates `Vehicle__c` records |
| **Data Layer** | `Vehicle__c`, `ConnectedVehicleSettings__mdt` | Stores and configures vehicle data and cache rules |

---

## 🛠️ Setup Notes
- Platform Cache partition name: **`ConnectedVehicles`**  
- Platform Event: **`Vehicle_Status__e`**  
- Named Credential (for future integration): **`Mule_Vehicle_API`**  
- Default Account for demo: **Champion Motors – Demo**  
- LWC is exposed under **Account → Details tab**

---

## 👤 Author
**Ronen Atias-Koliran**  

