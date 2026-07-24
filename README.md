# Travel Suite Pro - Architecture & System Design

> **Note to Reviewers:** This repository serves as a public architectural showcase and technical portfolio. Due to commercial integrity, the proprietary frontend source code (React) and private infrastructure credentials are not included. This repository exposes the core system design, AI orchestration logic, and PostgreSQL database schema (with strict RLS and Tenant Isolation) powering the application.

## Overview: What is Travel Suite Pro?

Travel Suite Pro — Overview                                                                                                                    
                                                                                                                                                 
  What It Is                                                                                                                                     
                                                                                                                                                 
  Travel Suite Pro is a B2B SaaS platform for tour operators and DMCs (Destination Management Companies) to build, price, quote, and manage      
  custom travel itineraries. It is a multi-tenant system where each organization operates in its own isolated workspace with full data separation
   enforced at the database level via Row-Level Security and JWT claims.                                                                         
                  
  Core Purpose                                                                                                                                   
  
  The platform replaces scattered spreadsheets, email chains, and manual报价 processes with a unified workflow: receive a client request →       
  analyze it → build a day-by-day itinerary → price it with markups → freeze the quote → send to the client → track through confirmation and
  operations.                                                                                                                                    
                  
  Tech Stack                                                                                                                                     
  
  - Frontend: React 18 + TypeScript + Vite 5 + SWC                                                                                               
  - Backend: Supabase (PostgreSQL 17, Auth, Storage, Edge Functions)
  - State & Data: TanStack Query v5, Zustand (UI only), react-hook-form + Zod                                                                    
  - UI: shadcn/ui (Radix primitives + Tailwind CSS)                                                                                              
  - AI Integration: n8n webhook → Google Gemini for natural language request analysis                                                            
                                                                                                                                                 
  ---                                                                                                                                            
  Full Feature Set                                                                                                                               
                                                                                                                                                 
  1. Service Catalog Management (Shell + Rates Pattern)
                                                                                                                                                 
  Every service type follows a Shell + Rates pattern — metadata lives on a "shell" table, while pricing lives on separate "rates" tables so      
  multiple suppliers can offer the same service at different prices:
                                                                                                                                                 
  ┌────────────────┬────────────────┬────────────────────────────────────────────────┬──────────────────────────────┐
  │    Service     │  Shell Table   │                  Rates Table                   │        Pricing Models        │
  ├────────────────┼────────────────┼────────────────────────────────────────────────┼──────────────────────────────┤
  │ Activities     │ activities     │ activity_rates                                 │ FIXED / PER_PAX / BASE_EXTRA │
  ├────────────────┼────────────────┼────────────────────────────────────────────────┼──────────────────────────────┤
  │ Accommodations │ accommodations │ accommodation_rooms → accommodation_room_rates │ Per-room, seasonal rates     │                            
  ├────────────────┼────────────────┼────────────────────────────────────────────────┼──────────────────────────────┤                            
  │ Transports     │ transports     │ transport_rates                                │ TRANSFER / DISPOSAL / FLIGHT │                            
  ├────────────────┼────────────────┼────────────────────────────────────────────────┼──────────────────────────────┤                            
  │ Guides         │ guides         │ guide_rates                                    │ Per-segment pricing          │
  ├────────────────┼────────────────┼────────────────────────────────────────────────┼──────────────────────────────┤                            
  │ Other Services │ other_services │ other_service_rates                            │ FIXED / PER_PAX              │
  └────────────────┴────────────────┴────────────────────────────────────────────────┴──────────────────────────────┘

  Each service supports images, location tagging, and soft-delete (is_active).                                                                   
  
  2. CRM & Partner Management                                                                                                                    
                  
  - Clients — Traveler profiles with passport data, nationality, DOB, dietary restrictions, agent referrals
  - Agents — Partner travel agencies with commission rates, consortium affiliations, banking info
  - Consortiums — Groups of agencies with default fee structures                                                                                 
  - Suppliers — Service providers by category, with linked service types and internal document storage
  - Locations — Destination catalog with geo-data, aliases, cover images, and usage statistics across services                                   
                  
  3. Itinerary Builder (Core Product)                                                                                                            
  
  The flagship feature — a full drag-and-drop day-by-day itinerary editor:                                                                       
                  
  - Timeline view — Days with itinerary items (activities, check-in/out, transfers, guides)
  - Service library panel — Search and select services from the catalog, filtered by location
  - Item details panel — Contextual editing for each service selection (rate choice, cost overrides, components)
  - Pax assignment — Assign travelers to the itinerary, designate lead passengers                                                                
  - Requirements checklist — Per-itinerary task tracking via itinerary_requirements
  - Internal notes — Per-itinerary notes for operator collaboration                                                                              
  - Room management — Room assignments per accommodation stay, with per-room pricing
  - Drag-and-drop reordering — Timeline items can be reordered via update_itinerary_items_positions RPC
                                                                                                                                                 
  4. AI-Powered Client Request Analysis
                                                                                                                                                 
  When a client sends a free-text trip request (e.g., "We are a family of 4 looking for a 7-day trip to Cancun in December with a budget of 
  $5,000"), the operator pastes it into the builder and triggers the AI analysis:

  1. Webhook call — The text is sent to an n8n workflow at https://n8n.collazolutions.space/webhook/request-analysis                             
  2. Gemini processing — n8n forwards the request to Google Gemini, which returns structured JSON
  3. Structured output stored in itineraries.request_analysis (JSONB):                                                                           
    - suggested_title — Auto-generated itinerary title
    - detected_budget — Estimated budget from the request
    - pax_count — Number of travelers detected
    - duration_days — Trip duration
    - start_date — Proposed start date
    - summary — Natural language summary of the request
    - preferences — Optional: room type, group size, travel style
    - checklist — Array of AI-generated action items, each with:                                                                                 
        - id — Unique identifier
      - text — Task description (e.g., "Find a 4-star hotel near the beach")                                                                     
      - category — Service type: activity, transport, accommodation, guide, other
      - done — Completion status (toggled via toggleChecklistItem mutation)

  5. Pricing & Markup Engine

  - Cost calculation — Pure functions in financials.ts using decimal.js for precision
  - Markup rules — Configurable per-agent or global, with conditions on client tier, trip duration, PAX count
  - Rule types: MARKUP (profit margin) and OVERHEAD (operational costs)
  - Action types: FIXED_PER_PAX, FIXED_TOTAL, PERCENTAGE
  - Priority-based — Rules are ordered and evaluated by priority
  - Net & Gross totals — Displayed in real-time during itinerary editing

  6. Quote Freeze & Price Snapshots

  When an itinerary is ready to send to the client, operators call freeze_itinerary_quote() which:

  - Atomically builds service_snapshot JSONB for every bridge row (stays, activities, transports, guides)                                        
  - Captures all selected rates, components, segments, and currency exchange info
  - Sets quote_valid_until = now() + 90 days                                                                                                     
  - Records exchange_rate_id and quote_sent_at

  Why this matters: Once a quote is sent, catalog price changes do not affect the quoted price. The snapshot permanently captures what was
  quoted. The frontend's compareWithSnapshot() function can flag discrepancies between current catalog prices and frozen quotes.

  7. RPC Functions (Backend API)

  40+ PostgreSQL functions organized by domain:

  - Tenant/Security — get_org_id(), get_auth_org_id(), org_id_jwt_hook(), handle_new_user(), resolve_storage_org_id()
  - Locations — get_or_create_location(), get_locations_with_stats(), get_orphan_locations()
  - Pending Services & Assignment — get_pending_services(), assign_unassigned_services(), batch_assign_services_v2()
  - Supplier Merge — merge_suppliers(), merge_suppliers_v2(), execute_merge_suppliers() (7 iterations to handle all edge cases)                  
  - Quote Snapshots — build_*_service_snapshot() (per entity), freeze_itinerary_quote() (atomic freeze)
  - Bulk Operations — rpc_bulk_soft_delete(), rpc_bulk_hard_delete(), rpc_bulk_insert()                                                          
  - Itinerary Operations — sync_stay_rooms(), update_itinerary_items_positions(), resurrect_record()
  - Team Management — update_team_member_role(), Edge Functions for invite/remove                                                                
                  
  8. Document & Image Management                                                                                                                 
  
  - Storage buckets — documents (private, for supplier contracts & internal docs) and media (public, for service images)                         
  - Storage RLS — Org-level isolation via JWT org_id claim extracted from storage object paths
  - Images stored as text[] URL arrays on service shells
  - Internal supplier docs stored as text[] on suppliers                                                                                         
  
  9. Team & Access Control                                                                                                                       
                  
  - Roles: ADMIN (full access, can manage team) and OPERATOR (can create/edit itineraries and services)
  - Multi-tenant isolation via organization_id on every table with RLS policies
  - JWT optimization — org_id injected into JWT claims via auth hook, avoiding per-query JOINs                                                   
  - Team management — Invite via email, role updates, user removal
                                                                                                                                                 
  10. Data Utilities

  - CSV import — Bulk service import with supplier resolution, location find-or-create, progress reporting                                       
  - JSON package export/import — Full data portability for service catalogs between organizations
                                                                                                                                                 
  ---             
  AI Roadmap: From AI Checklist to Pre-Itinerary

  Current State: AI-Generated Checklist

  Today, the AI (Gemini via n8n) produces a flat checklist of action items after analyzing a client request. Each checklist item has a category, 
  a description, and a done/undone toggle. The operator manually checks off items as they research and add services. Essentially, it is a smart 
  to-do list — helpful, but still requires the operator to do all the legwork of searching the catalog and assembling the itinerary piece by     
  piece.          

  The Evolution: AI-Generated Pre-Itinerary                                                                                                      
  
  The vision is to evolve this into a full pre-itinerary that the AI assembles automatically from the catalog:                                   
                  
  1. AI analyzes the client request (same as today) — detects destination, dates, PAX count, budget, preferences
  2. AI queries the service catalog — instead of just generating a checklist, the AI searches the platform's own database for:
    - Available accommodations matching the budget and preferences                                                                               
    - Activities offered in the destination region
    - Transfer options between locations                                                                                                         
    - Available guides with relevant expertise
  3. AI assembles a draft itinerary — a complete day-by-day structure with:
    - Suggested activities placed on specific days
    - Accommodation assignments per night                                                                                                        
    - Transfer scheduling between locations
    - Guide assignments                                                                                                                          
    - Preliminary pricing based on catalog rates
  4. Human operator reviews & refines — the operator acts as an editor and quality controller:
    - Adjusts day assignments
    - Swaps suggested services for alternatives
    - Fine-tunes pricing, applies markups
    - Adds personal notes and client-specific touches                                                                                            
  5. Operator freezes and sends the quote — the existing freeze_itinerary_quote workflow finalizes the price
                                                                                                                                                 
  Why This Matters

  - Dramatically reduces itinerary assembly time — from hours to minutes                                                                         
  - Operators focus on value-add — personalization, quality control, client relationships — instead of data entry
  - Faster quote turnaround — competitive advantage in a fast-moving market                                                                      
  - AI learns from operator corrections — the system can improve over time by analyzing which AI suggestions operators accept or reject
                                                                                                                                                 
  Technical Considerations for the Evolution
                                                                                                                                                 
  - Semantic search over the service catalog (currently basic text search) will need vector embeddings for meaningful AI matching
  - Constraint satisfaction — the AI must respect real-world logistics (e.g., you can't do a morning activity in Tulum and an afternoon one in
  Chichen Itza)                                                                                                                                  
  - Budget optimization — the AI should suggest services that fit within the detected budget, or flag trade-offs
  - Operator feedback loop — track which AI suggestions are accepted/rejected/modified to train a better model over time                         
                  

```mermaid
graph TD
    %% Entidades de Usuario
    Client([Client Request / Text])
    Operator([Travel Operator / Agent])

    %% Interfaz de Usuario
    subgraph Frontend [Client-Side React]
        UI[Optimistic UI Component]
        TSQ[TanStack Query - Server State]
        Zustand[Zustand - Pure UI State]
        Calc[Client-Side Decimal.js Engine]
    end

    %% Capa de Inteligencia Artificial
    subgraph AI [AI Extraction Pipeline]
        Prompt[System Prompt & Context]
        LLM{LLM Engine}
        JSON_Val[Strict JSON Schema Validator]
    end

    %% Base de Datos (Supabase / PostgreSQL)
    subgraph Supabase [Supabase PostgreSQL]
        JWT[JWT org_id Auth Hook]
        
        subgraph ShellRates [Shell and Rates Pattern]
            Shell[(Shell Tables: Metadata)]
            Rates[(Rate Tables: Pricing)]
        end
        
        Bridge[(Bridge Tables: itinerary_items)]
        RPC[[RPC: freeze_itinerary_quote]]
        Snap[(service_snapshot JSONB)]
    end

    %% Flujo de Ingesta IA
    Client -->|Unstructured Request| Prompt
    Prompt --> LLM
    LLM -->|Semantic Extraction| JSON_Val
    JSON_Val -->|Structured Itinerary Data| Bridge

    %% Flujo Frontend y Optimistic UI
    Operator -->|Drafts & Edits| UI
    UI -->|Mutation| TSQ
    TSQ -->|Optimistic Update| UI
    TSQ -->|Write via RLS| Bridge
    UI --- Zustand
    
    %% Flujo de Cálculos Financieros
    TSQ -->|Reads Live Rates| Calc
    TSQ -->|Reads Frozen Rates| Calc
    Rates -->|Live Price Feed| TSQ
    Snap -->|Frozen Price Feed| TSQ

    %% Flujo de Cotización (Snapshot)
    Operator -->|Sends Quote| RPC
    RPC -->|Atomically Writes| Snap
    Bridge --- Shell
    Bridge --- Rates

    %% Estilos para legibilidad corporativa
    style LLM fill:#e1bee7,stroke:#4a148c,stroke-width:2px
    style RPC fill:#bbdefb,stroke:#0d47a1,stroke-width:2px
    style JWT fill:#ffcdd2,stroke:#b71c1c,stroke-width:2px
    style Calc fill:#c8e6c9,stroke:#1b5e20,stroke-width:2px
```
## System Demo
[![Travel Suite Pro Demo](https://img.youtube.com/vi/v2QLugzN89s/0.jpg)](https://youtu.be/v2QLugzN89s)

## Core Principles

### I. Shell+Rates Pattern

Every service type (activities, transports, accommodations, guides, other
services) MUST follow the Shell+Rates architectural pattern:

- **Shell tables** store metadata only: name, service type, location,
  description — never pricing.
- **Rate tables** store per-supplier pricing: base_cost, pricing_model
  (FIXED/PER_PAX/BASE_EXTRA), currency_code.
- **Bridge tables** link a Shell service instance to an Itinerary, recording
  which Rate was selected and freezing a `service_snapshot JSONB` at quote time.
- **Child tables** decompose bridge items into sub-components (rooms, segments,
  activity components).

Rationale: This separation prevents pricing changes from corrupting historical
quotes, enables multi-supplier sourcing per service, and keeps the catalog
schema uniform across all 5 service types.

### II. Multi-tenant by Organization

Every public table MUST include an `organization_id` column with a foreign key
to `organizations.id`. RLS policies enforce tenant isolation:

- **Fast path**: `auth.jwt() ->> 'org_id'` reads the claim injected by the
  `org_id_jwt_hook()` auth trigger at login. Zero JOINs against `profiles`.
- **Fallback**: `SELECT organization_id FROM profiles WHERE id = auth.uid()` for
  legacy users without the JWT claim.
- **Storage RLS**: `(string_to_array(name, '/'))[1] = auth.jwt() ->> 'org_id'` —
  tenant isolation via first path segment, no subquery.
- **SECURITY DEFINER RPCs** (`freeze_itinerary_quote`, `rpc_rebuild_snapshot`)
  verify `v_org_id = v_auth_org` explicitly before mutation.

Rationale: A single seq-scan on profiles per policy check caused severe latency
under concurrent load. JWT claims eliminate this entirely.

### III. Snapshot-based Pricing Freeze

Quoted prices MUST be frozen at the moment of status transition to `quote_sent`:

- The RPC `freeze_itinerary_quote(p_itinerary_id)` atomically writes
  `service_snapshot JSONB` on all 4 bridge tables + sets `quote_valid_until`
  (90 days) and `quote_sent_at`.
- No database triggers write `service_snapshot`. All prior trigger-based
  approaches (outbox, synchronous cascade, JSONB AFTER triggers) were removed
  due to deadlock risk.
- `rpc_rebuild_snapshot()` exists for manual draft refresh but MUST skip frozen
  itineraries (idempotent — returns existing snapshot).
- The client `QuotationView` reads `service_snapshot` first; only falls back to
  live catalog rates when snapshot is NULL.

Rationale: Pricing integrity for sent quotes is non-negotiable. Catalog prices
change; sent quotes must not.

### IV. Client-Side Financial Calculations

All financial calculations MUST occur in the browser using `decimal.js` with
precision 20 and `ROUND_HALF_UP` rounding:

- `calculateActivityGroupCost()` / `calculateTransportGroupCost()` /
  `calculateRoomGroupCost()` compute from live catalog rates.
- `calculateActivityGroupCostFromSnapshot()` / `calculateTransportCostFromSnapshot()` /
  `calculateRoomCostFromSnapshot()` compute from frozen snapshot JSONB.
- `compareWithSnapshot()` detects cost drift (`|snapshot - current| > 0.01`),
  name changes, and service deletions.
- There MUST be NO server-side "calculate total" endpoint. Totals are derived
  client-side from individual bridge item costs.

Rationale: Eliminates network round-trips for financial feedback during drafting
and avoids server-side floating-point drift. The snapshot comparison enables the
UI to flag "price changed since quote was sent" without reloading.

### V. Optimistic UI with TanStack Query

Server state MUST be managed exclusively via TanStack Query, with Zustand
reserved for pure UI state (sidebar, modals, view mode, drag active id):

- All mutations MUST follow the optimistic update pattern:
  `onMutate: cancelQueries → snapshot → setQueryData; onError: restore snapshot;
  onSettled: invalidateQueries`.
- Query keys MUST be triple-keyed as `['resource', id, orgId]` for cache
  isolation across tenants.
- The query function MUST be disabled when the required ID or orgId is falsy.
- No server data MAY be stored in Zustand or any other global state store.

Rationale: Optimistic UI provides instant feedback during drafting. Triple-keyed
queries prevent cross-tenant cache leaks. Zustand-only-for-UI prevents the
common mistake of duplicating server state.

## Security & Compliance

### RLS and JWT Hardening

- All tables with `organization_id` MUST have exactly two RLS policies:
  - `Tenant Isolation <table>` for `authenticated` role: `USING (organization_id =
    get_auth_org_id()) WITH CHECK (organization_id = get_auth_org_id())`.
  - `RLS_<TableName>` for general access: `USING (organization_id = get_org_id()
    AND deleted_at IS NULL)`.
- JWT `org_id` claim MUST be injected on every login via the
  `org_id_jwt_hook()` trigger (`BEFORE UPDATE OF last_sign_in_at`).
- SECURITY DEFINER functions MUST use `SET search_path = ''` and explicitly
  verify org ownership before mutation.

### Soft-Delete Discipline

- All Shell and Rate tables (14 tables total) MUST implement soft delete via
  `deleted_at TIMESTAMPTZ` + `BEFORE DELETE` trigger (`trg_soft_delete`).
- Bridge tables (`itinerary_*`, `stay_rooms`, components, segments) MUST NOT
  have soft delete — their deletion is intentional document editing.
- Snapshot builder functions MUST filter `AND deleted_at IS NULL` in JOINs so
  frozen quotes capture or exclude deleted rates correctly.

### Multi-Currency Integrity

- All rate tables MUST have `currency_code CHAR(3) DEFAULT 'USD'`.
- Itineraries MUST have `base_currency CHAR(3) DEFAULT 'USD'`.
- At freeze time, the exchange rate metadata (rate, from, to, frozen timestamp)
  MUST be injected into every `service_snapshot` via the `||` JSONB operator.

## Data & Persistence

### Migration Discipline

- All schema changes MUST be additive SQL migrations in `supabase/migrations/`
  with the format `YYYYMMDDHHMMSS_description.sql`.
- Migrations MUST be idempotent: use `IF NOT EXISTS`, `DROP ... IF EXISTS`,
  and `ADD COLUMN IF NOT EXISTS` liberally.
- Each migration MUST have a header comment explaining purpose, changes, and
  any rollback considerations.
- Point-in-time recoverability: the sequence of migrations MUST produce the
  exact current schema when applied to a fresh database.

### Storage Organization

- Documents bucket: fully private, tenant-isolated via path prefix + JWT RLS.
- Media bucket: public reads, tenant-isolated writes.
- Path structure: `{bucket}/{org_id}/{itinerary_id}/{filename}`.

## Governance

This constitution supersedes all ad-hoc development practices. Amendments
require:

1. A documented proposal (PR or RFC) explaining the change and its rationale.
2. Review and approval by the project maintenance team.
3. Propagation of the change to all dependent templates (plan, spec, tasks
   templates if they reference affected principles).
4. A MAJOR version bump if principles are removed or redefined; MINOR for
   new principles or materially expanded guidance; PATCH for clarifications.

Compliance is verified during spec-kit planning (`/speckit-plan`) and
convergence (`/speckit-converge`) phases. Complexity must be justified when
any implementation violates a core principle.

**Version**: 1.0.0 | **Ratified**: 2026-07-18 | **Last Amended**: 2026-07-18
