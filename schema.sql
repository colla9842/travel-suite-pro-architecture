


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."itinerary_tier" AS ENUM (
    'STANDARD',
    'VIP',
    'VVIP'
);


ALTER TYPE "public"."itinerary_tier" OWNER TO "postgres";


CREATE TYPE "public"."markup_action_type" AS ENUM (
    'FIXED_PER_PAX',
    'FIXED_TOTAL',
    'PERCENTAGE'
);


ALTER TYPE "public"."markup_action_type" OWNER TO "postgres";


CREATE TYPE "public"."markup_condition_field" AS ENUM (
    'CLIENT_TIER',
    'TRIP_DURATION',
    'TOTAL_PAX'
);


ALTER TYPE "public"."markup_condition_field" OWNER TO "postgres";


CREATE TYPE "public"."markup_condition_operator" AS ENUM (
    'EQUALS',
    'GREATER_THAN',
    'LESS_THAN',
    'BETWEEN'
);


ALTER TYPE "public"."markup_condition_operator" OWNER TO "postgres";


CREATE TYPE "public"."markup_rule_type" AS ENUM (
    'MARKUP',
    'OVERHEAD'
);


ALTER TYPE "public"."markup_rule_type" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_unassigned_services"("target_supplier_id" "uuid", "org_id" "uuid", "accommodation_ids" "uuid"[], "transport_ids" "uuid"[], "activity_ids" "uuid"[], "guide_ids" "uuid"[], "other_service_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
BEGIN
  -- 1. Accommodations (Direct Link)
  IF array_length(accommodation_ids, 1) > 0 THEN
    UPDATE accommodations 
    SET supplier_id = target_supplier_id 
    WHERE id = ANY(accommodation_ids) AND organization_id = org_id;
  END IF;

  -- 2. Guides (Direct Link)
  IF array_length(guide_ids, 1) > 0 THEN
    UPDATE guides 
    SET supplier_id = target_supplier_id 
    WHERE id = ANY(guide_ids) AND organization_id = org_id;
  END IF;

  -- 3. Other Services (Direct Link)
  IF array_length(other_service_ids, 1) > 0 THEN
    UPDATE other_services 
    SET supplier_id = target_supplier_id 
    WHERE id = ANY(other_service_ids) AND organization_id = org_id;
  END IF;

  -- 4. Transports (Via Rates)
  -- If a transport has no rates, we create a default flat rate of $0 linked to this supplier.
  IF array_length(transport_ids, 1) > 0 THEN
    INSERT INTO transport_rates (transport_id, supplier_id, organization_id, cost, cost_out_city)
    SELECT id, target_supplier_id, org_id, 0, 0
    FROM transports
    WHERE id = ANY(transport_ids) AND organization_id = org_id
    ON CONFLICT DO NOTHING; -- Skip if a rate somehow already exists for this exact combination
  END IF;

  -- 5. Activities (Via Rates)
  -- If an activity has no rates, we create a default fixed rate of $0 linked to this supplier.
  IF array_length(activity_ids, 1) > 0 THEN
    INSERT INTO activity_rates (activity_id, supplier_id, organization_id, pricing_model, base_cost)
    SELECT id, target_supplier_id, org_id, 'FIXED', 0
    FROM activities
    WHERE id = ANY(activity_ids) AND organization_id = org_id
    ON CONFLICT DO NOTHING;
  END IF;

END;
$_$;


ALTER FUNCTION "public"."assign_unassigned_services"("target_supplier_id" "uuid", "org_id" "uuid", "accommodation_ids" "uuid"[], "transport_ids" "uuid"[], "activity_ids" "uuid"[], "guide_ids" "uuid"[], "other_service_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."batch_assign_services_v2"("p_org_id" "uuid", "p_supplier_id" "uuid", "p_items" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  item JSONB;
  v_id UUID;
  v_type TEXT;
BEGIN
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_id := (item->>'id')::UUID;
    v_type := item->>'type';

    IF v_type = 'accommodations' THEN
      UPDATE accommodations SET supplier_id = p_supplier_id WHERE id = v_id AND organization_id = p_org_id;
    
    ELSIF v_type = 'transports' THEN
      -- Create a stub rate for the transport to link it to the supplier
      INSERT INTO transport_rates (transport_id, supplier_id, organization_id, cost, cost_out_city)
      VALUES (v_id, p_supplier_id, p_org_id, 0, 0);

    ELSIF v_type = 'activities' THEN
      -- Create a stub rate for the activity
      INSERT INTO activity_rates (activity_id, supplier_id, organization_id, base_cost, pricing_model)
      VALUES (v_id, p_supplier_id, p_org_id, 0, 'FIXED');

    ELSIF v_type = 'guides' THEN
      UPDATE guides SET supplier_id = p_supplier_id WHERE id = v_id AND organization_id = p_org_id;
    
    ELSIF v_type = 'other_services' THEN
      UPDATE other_services SET supplier_id = p_supplier_id WHERE id = v_id AND organization_id = p_org_id;
    END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."batch_assign_services_v2"("p_org_id" "uuid", "p_supplier_id" "uuid", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_snapshot jsonb;
  v_act record;
BEGIN
  SELECT ia.activity_id, ia.selected_supplier_rate_id
  INTO v_act
  FROM public.itinerary_activities ia
  WHERE ia.id = p_activity_id;

  IF v_act.activity_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'activity_name', a.name,
    'activity_id', a.id,
    'supplier_name', sup.name,
    'supplier_contact', COALESCE(sup.contact_email, sup.contact_phone),
    'selected_rate', CASE WHEN v_act.selected_supplier_rate_id IS NOT NULL THEN
      jsonb_build_object(
        'rate_name', ar.name,
        'base_cost', ar.base_cost,
        'pricing_model', ar.pricing_model,
        'max_capacity', ar.max_capacity,
        'extra_pax_cost', ar.extra_pax_cost
      )
    ELSE NULL END,
    'components', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'component_id', iac.id,
            'rate_name', COALESCE(iac.snapshot_rate_name, acr.name),
            'base_cost', COALESCE(iac.snapshot_unit_cost, acr.base_cost, 0),
            'quantity', iac.quantity,
            'custom_price', iac.custom_price
          )
          ORDER BY acr.name
        )
        FROM public.itinerary_activity_components iac
        LEFT JOIN public.activity_rates acr ON acr.id = iac.activity_rate_id AND acr.deleted_at IS NULL
        WHERE iac.itinerary_activity_id = p_activity_id
      ),
      '[]'::jsonb
    )
  ) INTO v_snapshot
  FROM public.activities a
  LEFT JOIN public.activity_rates ar ON ar.id = v_act.selected_supplier_rate_id AND ar.deleted_at IS NULL
  LEFT JOIN public.suppliers sup ON sup.id = ar.supplier_id
  WHERE a.id = v_act.activity_id AND a.deleted_at IS NULL;

  RETURN v_snapshot;
END;
$$;


ALTER FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid", "p_activity_fk" "uuid" DEFAULT NULL::"uuid", "p_rate_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_snapshot jsonb;
  v_act_id uuid;
  v_rate_id uuid;
BEGIN
  IF p_activity_fk IS NULL THEN
    SELECT ia.activity_id, ia.selected_supplier_rate_id
    INTO v_act_id, v_rate_id
    FROM public.itinerary_activities ia
    WHERE ia.id = p_activity_id;
  ELSE
    v_act_id := p_activity_fk;
    v_rate_id := p_rate_id;
  END IF;

  IF v_act_id IS NULL THEN
    -- Preserve existing snapshot if the activity was already unlinked
    SELECT ia.service_snapshot INTO v_snapshot
    FROM public.itinerary_activities ia
    WHERE ia.id = p_activity_id;
    RETURN v_snapshot;
  END IF;

  SELECT jsonb_build_object(
    'activity_name', a.name,
    'activity_id', a.id,
    'supplier_name', sup.name,
    'supplier_contact', COALESCE(sup.contact_email, sup.contact_phone),
    'selected_rate', CASE WHEN v_rate_id IS NOT NULL THEN
      jsonb_build_object(
        'rate_name', ar.name,
        'base_cost', ar.base_cost,
        'pricing_model', ar.pricing_model,
        'max_capacity', ar.max_capacity,
        'extra_pax_cost', ar.extra_pax_cost
      )
    ELSE NULL END,
    'components', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'component_id', iac.id,
            'rate_name', COALESCE(iac.snapshot_rate_name, acr.name),
            'base_cost', COALESCE(iac.snapshot_unit_cost, acr.base_cost, 0),
            'quantity', iac.quantity,
            'custom_price', iac.custom_price
          )
          ORDER BY acr.name
        )
        FROM public.itinerary_activity_components iac
        LEFT JOIN public.activity_rates acr ON acr.id = iac.activity_rate_id
        WHERE iac.itinerary_activity_id = p_activity_id
      ),
      '[]'::jsonb
    )
  ) INTO v_snapshot
  FROM public.activities a
  LEFT JOIN public.activity_rates ar ON ar.id = v_rate_id
  LEFT JOIN public.suppliers sup ON sup.id = ar.supplier_id
  WHERE a.id = v_act_id;

  RETURN v_snapshot;
END;
$$;


ALTER FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid", "p_activity_fk" "uuid", "p_rate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_snapshot jsonb;
  v_gd record;
BEGIN
  SELECT ig.guide_id, ig.selected_rate_id
  INTO v_gd
  FROM public.itinerary_guides ig
  WHERE ig.id = p_guide_id;

  IF v_gd.guide_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'guide_name', g.name,
    'guide_id', g.id,
    'is_freelance', g.is_freelance,
    'languages', g.languages,
    'supplier_name', sup.name,
    'supplier_contact', COALESCE(sup.contact_email, sup.contact_phone),
    'selected_rate', CASE WHEN v_gd.selected_rate_id IS NOT NULL THEN
      jsonb_build_object(
        'rate_name', gr.name,
        'price', gr.price
      )
    ELSE NULL END,
    'segments', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'segment_id', igs.id,
            'segment_name', igs.name,
            'rate_name', COALESCE(igs.snapshot_segment_name, gsr.name),
            'price', COALESCE(igs.snapshot_unit_cost, gsr.price, 0),
            'quantity', igs.quantity,
            'sell_price', igs.sell_price,
            'total_price', igs.total_price
          )
          ORDER BY igs.name
        )
        FROM public.itinerary_guide_segments igs
        LEFT JOIN public.guide_rates gsr ON gsr.id = igs.guide_rate_id AND gsr.deleted_at IS NULL
        WHERE igs.itinerary_guide_id = p_guide_id
      ),
      '[]'::jsonb
    )
  ) INTO v_snapshot
  FROM public.guides g
  LEFT JOIN public.guide_rates gr ON gr.id = v_gd.selected_rate_id AND gr.deleted_at IS NULL
  LEFT JOIN public.suppliers sup ON sup.id = g.supplier_id
  WHERE g.id = v_gd.guide_id AND g.deleted_at IS NULL;

  RETURN v_snapshot;
END;
$$;


ALTER FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid", "p_guide_fk" "uuid" DEFAULT NULL::"uuid", "p_rate_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_snapshot jsonb;
  v_guide_id uuid;
  v_rate_id uuid;
BEGIN
  IF p_guide_fk IS NULL THEN
    SELECT ig.guide_id, ig.selected_rate_id
    INTO v_guide_id, v_rate_id
    FROM public.itinerary_guides ig
    WHERE ig.id = p_guide_id;
  ELSE
    v_guide_id := p_guide_fk;
    v_rate_id := p_rate_id;
  END IF;

  IF v_guide_id IS NULL THEN
    SELECT ig.service_snapshot INTO v_snapshot
    FROM public.itinerary_guides ig
    WHERE ig.id = p_guide_id;
    RETURN v_snapshot;
  END IF;

  SELECT jsonb_build_object(
    'guide_name', g.name,
    'guide_id', g.id,
    'is_freelance', g.is_freelance,
    'languages', g.languages,
    'supplier_name', sup.name,
    'supplier_contact', COALESCE(sup.contact_email, sup.contact_phone),
    'selected_rate', CASE WHEN v_rate_id IS NOT NULL THEN
      jsonb_build_object(
        'rate_name', gr.name,
        'price', gr.price
      )
    ELSE NULL END,
    'segments', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'segment_id', igs.id,
            'segment_name', igs.name,
            'rate_name', COALESCE(igs.snapshot_segment_name, gsr.name),
            'price', COALESCE(igs.snapshot_unit_cost, gsr.price, 0),
            'quantity', igs.quantity,
            'sell_price', igs.sell_price,
            'total_price', igs.total_price
          )
          ORDER BY igs.name
        )
        FROM public.itinerary_guide_segments igs
        LEFT JOIN public.guide_rates gsr ON gsr.id = igs.guide_rate_id
        WHERE igs.itinerary_guide_id = p_guide_id
      ),
      '[]'::jsonb
    )
  ) INTO v_snapshot
  FROM public.guides g
  LEFT JOIN public.guide_rates gr ON gr.id = v_rate_id
  LEFT JOIN public.suppliers sup ON sup.id = g.supplier_id
  WHERE g.id = v_guide_id;

  RETURN v_snapshot;
END;
$$;


ALTER FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid", "p_guide_fk" "uuid", "p_rate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_snapshot jsonb;
  v_acc_id uuid;
BEGIN
  SELECT s.accommodation_id INTO v_acc_id
  FROM public.itinerary_stays s
  WHERE s.id = p_stay_id;

  IF v_acc_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'accommodation_name', a.name,
    'accommodation_id', a.id,
    'supplier_name', sup.name,
    'supplier_contact', COALESCE(sup.contact_email, sup.contact_phone),
    'rooms', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'room_name', COALESCE(sr.snapshot_room_name, ar.name),
            'rate', COALESCE(sr.snapshot_unit_cost, ar.rate_high, 0),
            'quantity', sr.quantity,
            'pax_per_room', sr.pax_per_room,
            'sell_price_per_night', sr.sell_price_per_night,
            'total_room_cost', sr.total_room_cost,
            'season_name', (SELECT asns.name FROM public.accommodation_room_rates arrr
              LEFT JOIN public.accommodation_seasons asns ON asns.id = arrr.season_id
              WHERE arrr.id = sr.selected_supplier_rate_id)
          )
          ORDER BY ar.name
        )
        FROM public.stay_rooms sr
        LEFT JOIN public.accommodation_rooms ar ON ar.id = sr.room_id
        WHERE sr.stay_id = p_stay_id
      ),
      '[]'::jsonb
    )
  ) INTO v_snapshot
  FROM public.accommodations a
  LEFT JOIN public.suppliers sup ON sup.id = a.supplier_id
  WHERE a.id = v_acc_id;

  RETURN v_snapshot;
END;
$$;


ALTER FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid", "p_accommodation_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_snapshot jsonb;
  v_acc_id uuid;
BEGIN
  IF p_accommodation_id IS NULL THEN
    SELECT s.accommodation_id INTO v_acc_id
    FROM public.itinerary_stays s
    WHERE s.id = p_stay_id;
  ELSE
    v_acc_id := p_accommodation_id;
  END IF;

  IF v_acc_id IS NULL THEN
    -- Preserve existing snapshot if the accommodation was already unlinked
    -- (e.g. by nullifyItineraryRefs running in parallel with the cascade trigger)
    SELECT s.service_snapshot INTO v_snapshot
    FROM public.itinerary_stays s
    WHERE s.id = p_stay_id;
    RETURN v_snapshot;
  END IF;

  SELECT jsonb_build_object(
    'accommodation_name', a.name,
    'accommodation_id', a.id,
    'supplier_name', sup.name,
    'supplier_contact', COALESCE(sup.contact_email, sup.contact_phone),
    'rooms', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'room_name', COALESCE(sr.snapshot_room_name, ar.name),
            'rate', COALESCE(sr.snapshot_unit_cost, ar.rate_high, 0),
            'quantity', sr.quantity,
            'pax_per_room', sr.pax_per_room,
            'sell_price_per_night', sr.sell_price_per_night,
            'total_room_cost', sr.total_room_cost,
            'season_name', (SELECT asns.name FROM public.accommodation_room_rates arrr
              LEFT JOIN public.accommodation_seasons asns ON asns.id = arrr.season_id
              WHERE arrr.id = sr.selected_supplier_rate_id)
          )
          ORDER BY ar.name
        )
        FROM public.stay_rooms sr
        LEFT JOIN public.accommodation_rooms ar ON ar.id = sr.room_id
        WHERE sr.stay_id = p_stay_id
      ),
      '[]'::jsonb
    )
  ) INTO v_snapshot
  FROM public.accommodations a
  LEFT JOIN public.suppliers sup ON sup.id = a.supplier_id
  WHERE a.id = v_acc_id;

  RETURN v_snapshot;
END;
$$;


ALTER FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid", "p_accommodation_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_snapshot jsonb;
  v_tpt record;
BEGIN
  SELECT it.transport_id, it.selected_supplier_rate_id
  INTO v_tpt
  FROM public.itinerary_transports it
  WHERE it.id = p_transport_id;

  IF v_tpt.transport_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'transport_name', t.name,
    'transport_id', t.id,
    'service_type', t.service_type,
    'vehicle_type', t.vehicle_type,
    'supplier_name', sup.name,
    'supplier_contact', COALESCE(sup.contact_email, sup.contact_phone),
    'selected_rate', CASE WHEN v_tpt.selected_supplier_rate_id IS NOT NULL THEN
      jsonb_build_object(
        'rate_id', tr.id,
        'cost', tr.cost,
        'cost_out_city', tr.cost_out_city,
        'fuel_policy', tr.fuel_policy,
        'notes', tr.notes
      )
    ELSE NULL END
  ) INTO v_snapshot
  FROM public.transports t
  LEFT JOIN public.transport_rates tr ON tr.id = v_tpt.selected_supplier_rate_id AND tr.deleted_at IS NULL
  LEFT JOIN public.suppliers sup ON sup.id = tr.supplier_id
  WHERE t.id = v_tpt.transport_id AND t.deleted_at IS NULL;

  RETURN v_snapshot;
END;
$$;


ALTER FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid", "p_transport_fk" "uuid" DEFAULT NULL::"uuid", "p_rate_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_snapshot jsonb;
  v_tpt_id uuid;
  v_rate_id uuid;
BEGIN
  IF p_transport_fk IS NULL THEN
    SELECT it.transport_id, it.selected_supplier_rate_id
    INTO v_tpt_id, v_rate_id
    FROM public.itinerary_transports it
    WHERE it.id = p_transport_id;
  ELSE
    v_tpt_id := p_transport_fk;
    v_rate_id := p_rate_id;
  END IF;

  IF v_tpt_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'transport_name', t.name,
    'transport_id', t.id,
    'service_type', t.service_type,
    'vehicle_type', t.vehicle_type,
    'supplier_name', sup.name,
    'supplier_contact', COALESCE(sup.contact_email, sup.contact_phone),
    'selected_rate', CASE WHEN v_rate_id IS NOT NULL THEN
      jsonb_build_object(
        'rate_id', tr.id,
        'cost', tr.cost,
        'cost_out_city', tr.cost_out_city,
        'fuel_policy', tr.fuel_policy,
        'notes', tr.notes
      )
    ELSE NULL END
  ) INTO v_snapshot
  FROM public.transports t
  LEFT JOIN public.transport_rates tr ON tr.id = v_rate_id
  LEFT JOIN public.suppliers sup ON sup.id = tr.supplier_id
  WHERE t.id = v_tpt_id;

  RETURN v_snapshot;
END;
$$;


ALTER FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid", "p_transport_fk" "uuid", "p_rate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."execute_merge_suppliers"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text" DEFAULT NULL::"text", "merged_phone" "text" DEFAULT NULL::"text", "merged_category" "text" DEFAULT NULL::"text", "merged_tags" "text"[] DEFAULT '{}'::"text"[], "merged_internal_docs" "text"[] DEFAULT '{}'::"text"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_auth_org uuid;
    v_keeper_org uuid;
    v_discarded_org uuid;
BEGIN
    v_auth_org := public.get_auth_org_id();
    SELECT organization_id INTO v_keeper_org FROM public.suppliers WHERE id = keeper_id;
    SELECT organization_id INTO v_discarded_org FROM public.suppliers WHERE id = discarded_id;

    IF v_keeper_org IS NULL OR v_discarded_org IS NULL THEN 
        RAISE EXCEPTION 'Suppliers not found.'; 
    END IF;
    
    IF v_keeper_org != v_auth_org OR v_discarded_org != v_auth_org THEN 
        RAISE EXCEPTION 'Unauthorized: Tenant isolation breach detected.'; 
    END IF;

    -- Liberar el email del proveedor descartado (Soft Delete)
    UPDATE public.suppliers 
    SET contact_email = NULL, contact_phone = NULL, is_active = false
    WHERE id = discarded_id;

    -- Actualizar el proveedor principal asegurando que "" se convierta en NULL real
    UPDATE public.suppliers 
    SET name = merged_name, 
        contact_email = NULLIF(TRIM(merged_email), ''), 
        contact_phone = NULLIF(TRIM(merged_phone), ''), 
        category = merged_category, 
        tags = merged_tags, 
        internal_docs = merged_internal_docs 
    WHERE id = keeper_id;

    -- Mover referencias
    UPDATE public.accommodations SET supplier_id = keeper_id WHERE supplier_id = discarded_id;
    UPDATE public.guides SET supplier_id = keeper_id WHERE supplier_id = discarded_id;
    UPDATE public.other_services SET supplier_id = keeper_id WHERE supplier_id = discarded_id;

    -- Mover tarifas previniendo duplicados
    DELETE FROM public.transport_rates WHERE supplier_id = discarded_id AND transport_id IN (SELECT transport_id FROM public.transport_rates WHERE supplier_id = keeper_id);
    UPDATE public.transport_rates SET supplier_id = keeper_id WHERE supplier_id = discarded_id;

    DELETE FROM public.activity_rates WHERE supplier_id = discarded_id AND activity_id IN (SELECT activity_id FROM public.activity_rates WHERE supplier_id = keeper_id);
    UPDATE public.activity_rates SET supplier_id = keeper_id WHERE supplier_id = discarded_id;
END;
$$;


ALTER FUNCTION "public"."execute_merge_suppliers"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "text"[], "merged_internal_docs" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_sync_supplier_service_types"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_supplier_id UUID;
BEGIN
    IF (TG_OP = 'DELETE') THEN
        v_supplier_id := OLD.supplier_id;
    ELSE
        v_supplier_id := NEW.supplier_id;
    END IF;

    IF v_supplier_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- AHORA CON RUTAS ABSOLUTAS: 'public.table_name'
    UPDATE public.suppliers 
    SET service_types = ARRAY(
        SELECT DISTINCT category
        FROM (
            SELECT 'Accommodation' as category FROM public.accommodations WHERE supplier_id = v_supplier_id
            UNION
            SELECT 'Activity' as category FROM public.activity_rates WHERE supplier_id = v_supplier_id
            UNION
            SELECT 'Transport' as category FROM public.transport_rates WHERE supplier_id = v_supplier_id
            UNION
            SELECT 'Guide' as category FROM public.guides WHERE supplier_id = v_supplier_id
            UNION
            SELECT 'Other Services' as category FROM public.other_services WHERE supplier_id = v_supplier_id
        ) sub
        WHERE category IS NOT NULL
    )
    WHERE id = v_supplier_id;

    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."fn_sync_supplier_service_types"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."freeze_itinerary_quote"("p_itinerary_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_org_id          uuid;
    v_auth_org        uuid;
    v_it_status       text;
    v_now             timestamptz := now();
    v_base_currency   char(3);
    v_exchange_rate_id uuid;
    v_exchange_rate   numeric(18,8);
    v_exchange_from   char(3);
    v_exchange_to     char(3);
    v_currency_meta   jsonb;
BEGIN
    -- ── 1. Authorization: resolve caller's org ──
    v_auth_org := public.get_auth_org_id();
    IF v_auth_org IS NULL THEN
        RAISE EXCEPTION 'Not authenticated'
            USING ERRCODE = 'P0001';
    END IF;

    -- ── 2. Load itinerary and verify org ownership ──
    SELECT i.organization_id, i.status, i.base_currency, i.exchange_rate_id
    INTO v_org_id, v_it_status, v_base_currency, v_exchange_rate_id
    FROM public.itineraries i
    WHERE i.id = p_itinerary_id;

    IF v_org_id IS NULL THEN
        RAISE EXCEPTION 'Itinerary not found'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_org_id != v_auth_org THEN
        RAISE EXCEPTION 'Unauthorized: organization mismatch'
            USING ERRCODE = 'P0001';
    END IF;

    -- ── 3. Check status — only freeze if not already frozen ──
    IF v_it_status IN ('confirmed', 'operations', 'completed') THEN
        RAISE EXCEPTION 'Cannot freeze itinerary in status %: already beyond quote stage', v_it_status
            USING ERRCODE = 'P0001';
    END IF;

    -- ── 4. Build currency metadata to inject into every snapshot ──
    v_currency_meta := jsonb_build_object(
        'base_currency', v_base_currency
    );

    IF v_exchange_rate_id IS NOT NULL THEN
        SELECT er.rate, er.from_currency, er.to_currency
        INTO v_exchange_rate, v_exchange_from, v_exchange_to
        FROM public.exchange_rates er
        WHERE er.id = v_exchange_rate_id;

        v_currency_meta := jsonb_build_object(
            'base_currency', v_base_currency,
            'exchange_rate_id', v_exchange_rate_id,
            'exchange_rate', v_exchange_rate,
            'exchange_from', v_exchange_from,
            'exchange_to', v_exchange_to,
            'exchange_rate_frozen_at', v_now
        );
    END IF;

    -- ── 5. Freeze all service_snapshot JSONBs with currency metadata ──

    --   5a. itinerary_stays
    UPDATE public.itinerary_stays s
    SET service_snapshot = public.build_stay_service_snapshot(s.id) || v_currency_meta
    WHERE s.itinerary_id = p_itinerary_id;

    --   5b. itinerary_activities (includes components via builder)
    UPDATE public.itinerary_activities a
    SET service_snapshot = public.build_activity_service_snapshot(a.id) || v_currency_meta
    WHERE a.itinerary_id = p_itinerary_id;

    --   5c. itinerary_transports
    UPDATE public.itinerary_transports t
    SET service_snapshot = public.build_transport_service_snapshot(t.id) || v_currency_meta
    WHERE t.itinerary_id = p_itinerary_id;

    --   5d. itinerary_guides (includes segments via builder)
    UPDATE public.itinerary_guides g
    SET service_snapshot = public.build_guide_service_snapshot(g.id) || v_currency_meta
    WHERE g.itinerary_id = p_itinerary_id;

    -- ── 6. Set quote validity + sent timestamp ──
    UPDATE public.itineraries
    SET
        quote_valid_until = v_now + INTERVAL '90 days',
        quote_sent_at     = v_now
    WHERE id = p_itinerary_id;

END;
$$;


ALTER FUNCTION "public"."freeze_itinerary_quote"("p_itinerary_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."freeze_itinerary_quote"("p_itinerary_id" "uuid") IS 'Atomically freezes all service_snapshot JSONB for an itinerary, injecting currency metadata (base_currency, exchange_rate). Sets quote_valid_until (90 days) and quote_sent_at.';



CREATE OR REPLACE FUNCTION "public"."get_auth_org_id"() RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_org_id uuid;
BEGIN
  -- Fast path: read directly from JWT custom claims (no JOIN, no table access)
  BEGIN
    v_org_id := (auth.jwt() ->> 'org_id')::uuid;
    IF v_org_id IS NOT NULL THEN
      RETURN v_org_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Fall through to profiles lookup
  END;

  -- Fallback: read from profiles (legacy / first-time users without claim)
  SELECT organization_id INTO v_org_id
  FROM public.profiles
  WHERE id = auth.uid();

  RETURN v_org_id;
END;
$$;


ALTER FUNCTION "public"."get_auth_org_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_locations_with_stats"("org_id" "uuid") RETURNS TABLE("id" "uuid", "name" "text", "accommodation_count" bigint, "activity_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    l.id,
    l.name,
    COUNT(DISTINCT acc.id) AS accommodation_count,
    COUNT(DISTINCT act.id) AS activity_count
  FROM 
    locations l
  LEFT JOIN 
    accommodations acc ON acc.location_id = l.id
  LEFT JOIN 
    activities act ON act.location_id = l.id
  WHERE 
    l.organization_id = org_id
  GROUP BY 
    l.id, l.name
  ORDER BY 
    l.name;
END;
$$;


ALTER FUNCTION "public"."get_locations_with_stats"("org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_or_create_location"("p_name" "text", "p_country_code" "text", "p_org_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_location_id uuid;
  v_normalized text;
BEGIN
  v_normalized := LOWER(TRIM(p_name));

  -- Intento 1: SELECT optimista (camino rápido, sin escritura)
  SELECT id INTO v_location_id
  FROM public.locations
  WHERE organization_id = p_org_id
    AND LOWER(TRIM(name)) = v_normalized
    AND (country_code = p_country_code OR (country_code IS NULL AND p_country_code IS NULL))
  LIMIT 1;

  IF v_location_id IS NOT NULL THEN
    RETURN v_location_id;
  END IF;

  -- Intento 2: INSERT atómico con ON CONFLICT (seguro contra race conditions)
  INSERT INTO public.locations (organization_id, name, country_code)
  VALUES (p_org_id, p_name, p_country_code)
  ON CONFLICT (organization_id, LOWER(TRIM(name))) DO UPDATE
    SET name = EXCLUDED.name
  RETURNING id INTO v_location_id;

  RETURN v_location_id;
END;
$$;


ALTER FUNCTION "public"."get_or_create_location"("p_name" "text", "p_country_code" "text", "p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_org_id"() RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
  v_org_id uuid;
BEGIN
  -- Fast path: JWT
  BEGIN
    v_org_id := (auth.jwt() ->> 'org_id')::uuid;
    IF v_org_id IS NOT NULL THEN
      RETURN v_org_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- Fallback
  SELECT organization_id INTO v_org_id FROM public.profiles WHERE id = auth.uid();
  RETURN v_org_id;
END;
$$;


ALTER FUNCTION "public"."get_org_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_orphan_locations"("org_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    accs JSONB;
    acts JSONB;
    guis JSONB;
    trs JSONB;
    total INT;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'type', 'accommodation', 'detail', 'Accommodation')), '[]'::jsonb) INTO accs FROM accommodations WHERE organization_id = org_id AND location_id IS NULL;
    
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'type', 'activity', 'detail', 'Activity')), '[]'::jsonb) INTO acts FROM activities WHERE organization_id = org_id AND location_id IS NULL;
    
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'type', 'guide', 'detail', 'Guide')), '[]'::jsonb) INTO guis FROM guides WHERE organization_id = org_id AND location_id IS NULL;
    
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'type', 'transport', 'detail', 'Transport (' || vehicle_type || ')')), '[]'::jsonb) INTO trs FROM transports WHERE organization_id = org_id AND origin_id IS NULL;

    total := jsonb_array_length(accs) + jsonb_array_length(acts) + jsonb_array_length(guis) + jsonb_array_length(trs);

    RETURN jsonb_build_object(
        'accommodations', accs,
        'activities', acts,
        'guides', guis,
        'transports', trs,
        'total', total
    );
END;
$$;


ALTER FUNCTION "public"."get_orphan_locations"("org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pending_services"("org_id" "uuid") RETURNS TABLE("id" "uuid", "type" "text", "name" "text", "detail" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  -- 1. Accommodations without supplier_id
  SELECT a.id, 'accommodations'::TEXT as type, a.name, a.location_id::TEXT as detail
  FROM accommodations a
  WHERE a.organization_id = org_id AND a.supplier_id IS NULL

  UNION ALL

  -- 2. Transports without any rates
  SELECT t.id, 'transports'::TEXT as type, t.name, t.service_type::TEXT as detail
  FROM transports t
  LEFT JOIN transport_rates tr ON tr.transport_id = t.id
  WHERE t.organization_id = org_id AND tr.id IS NULL

  UNION ALL

  -- 3. Activities without any rates
  SELECT ac.id, 'activities'::TEXT as type, ac.name, ac.location_id::TEXT as detail
  FROM activities ac
  LEFT JOIN activity_rates ar ON ar.activity_id = ac.id
  WHERE ac.organization_id = org_id AND ar.id IS NULL

  UNION ALL

  -- 4. Guides without supplier_id and NOT freelance
  SELECT g.id, 'guides'::TEXT as type, g.name, g.languages::TEXT as detail
  FROM guides g
  WHERE g.organization_id = org_id AND g.is_freelance = false AND g.supplier_id IS NULL

  UNION ALL

  -- 5. Other Services without supplier_id
  -- Use description (safe column that exists in all environments)
  SELECT os.id, 'other_services'::TEXT as type, os.name, os.description as detail
  FROM other_services os
  WHERE os.organization_id = org_id AND os.supplier_id IS NULL;
END;
$$;


ALTER FUNCTION "public"."get_pending_services"("org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  target_org_id UUID;
  target_role TEXT := 'ADMIN';
BEGIN
  -- 1. Verificamos si es una invitación directa desde el Backend (Edge Function)
  IF NEW.raw_user_meta_data->>'is_invite' = 'true' THEN
    target_org_id := (NEW.raw_user_meta_data->>'organization_id')::UUID;
    target_role := NEW.raw_user_meta_data->>'role';
  END IF;

  -- 2. Si no es invitado, es un registro nuevo (crea la organización)
  IF target_org_id IS NULL THEN
    INSERT INTO public.organizations (name)
    VALUES (COALESCE(NEW.raw_user_meta_data->>'agency_name', 'Mi Agencia'))
    RETURNING id INTO target_org_id;
  END IF;

  -- 3. Crear el perfil vinculado
  INSERT INTO public.profiles (id, organization_id, first_name, last_name, email, role)
  VALUES (
    NEW.id,
    target_org_id,
    NEW.raw_user_meta_data->>'first_name',
    NEW.raw_user_meta_data->>'last_name',
    NEW.email,
    target_role
  );

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."merge_suppliers"("p_payload" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_keeper_id uuid;
    v_discarded_id uuid;
    v_merged_name text;
    v_merged_email text;
    v_merged_phone text;
    v_merged_category text;
    v_merged_tags text[];
    v_merged_internal_docs text[];
    v_auth_org uuid;
    v_keeper_org uuid;
    v_discarded_org uuid;
BEGIN
    -- Desempaquetado blindado (si falta algo, será nulo, pero la función no colapsará en un 404)
    v_keeper_id := (p_payload->>'keeper_id')::uuid;
    v_discarded_id := (p_payload->>'discarded_id')::uuid;
    v_merged_name := p_payload->>'merged_name';
    v_merged_email := p_payload->>'merged_email';
    v_merged_phone := p_payload->>'merged_phone';
    v_merged_category := p_payload->>'merged_category';
    
    -- Parseo seguro de arreglos. Si vienen vacíos o nulos, forzamos un array vacío '[]'
    v_merged_tags := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_payload->'merged_tags', '[]'::jsonb)));
    v_merged_internal_docs := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_payload->'merged_internal_docs', '[]'::jsonb)));

    -- Validaciones de seguridad
    v_auth_org := public.get_auth_org_id();
    SELECT organization_id INTO v_keeper_org FROM public.suppliers WHERE id = v_keeper_id;
    SELECT organization_id INTO v_discarded_org FROM public.suppliers WHERE id = v_discarded_id;
    
    IF v_keeper_org IS NULL OR v_discarded_org IS NULL THEN 
        RAISE EXCEPTION 'One or both suppliers not found. Check UUIDs.'; 
    END IF;
    
    IF v_keeper_org != v_auth_org OR v_discarded_org != v_auth_org THEN 
        RAISE EXCEPTION 'Unauthorized: Tenant isolation breach detected.'; 
    END IF;

    -- 1. EVITAR COLISIÓN DE UNIQUE INDEX (Soft delete primero)
    UPDATE public.suppliers 
    SET contact_email = NULL, 
        contact_phone = NULL, 
        is_active = false
    WHERE id = v_discarded_id;

    -- 2. Actualizar el proveedor que se queda (Keeper)
    UPDATE public.suppliers 
    SET name = v_merged_name, 
        contact_email = NULLIF(TRIM(v_merged_email), ''), 
        contact_phone = NULLIF(TRIM(v_merged_phone), ''), 
        category = v_merged_category, 
        tags = COALESCE(v_merged_tags, '{}'::text[]), 
        internal_docs = COALESCE(v_merged_internal_docs, '{}'::text[]) 
    WHERE id = v_keeper_id;

    -- 3. Migrar las relaciones simples
    UPDATE public.accommodations SET supplier_id = v_keeper_id WHERE supplier_id = v_discarded_id;
    UPDATE public.guides SET supplier_id = v_keeper_id WHERE supplier_id = v_discarded_id;
    UPDATE public.other_services SET supplier_id = v_keeper_id WHERE supplier_id = v_discarded_id;

    -- 4. Migrar las relaciones complejas asegurando que no existan duplicados de tarifas
    DELETE FROM public.transport_rates 
    WHERE supplier_id = v_discarded_id 
      AND transport_id IN (SELECT transport_id FROM public.transport_rates WHERE supplier_id = v_keeper_id);
      
    UPDATE public.transport_rates SET supplier_id = v_keeper_id WHERE supplier_id = v_discarded_id;

    DELETE FROM public.activity_rates 
    WHERE supplier_id = v_discarded_id 
      AND activity_id IN (SELECT activity_id FROM public.activity_rates WHERE supplier_id = v_keeper_id);
      
    UPDATE public.activity_rates SET supplier_id = v_keeper_id WHERE supplier_id = v_discarded_id;

END;
$$;


ALTER FUNCTION "public"."merge_suppliers"("p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."merge_suppliers_v2"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "jsonb" DEFAULT '[]'::"jsonb", "merged_internal_docs" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_auth_org uuid;
    v_keeper_org uuid;
    v_discarded_org uuid;
    v_tags text[];
    v_docs text[];
BEGIN
    SELECT ARRAY(SELECT jsonb_array_elements_text(COALESCE(merged_tags, '[]'::jsonb))) INTO v_tags;
    SELECT ARRAY(SELECT jsonb_array_elements_text(COALESCE(merged_internal_docs, '[]'::jsonb))) INTO v_docs;

    v_auth_org := public.get_auth_org_id();
    SELECT organization_id INTO v_keeper_org FROM public.suppliers WHERE id = keeper_id;
    SELECT organization_id INTO v_discarded_org FROM public.suppliers WHERE id = discarded_id;

    IF v_keeper_org IS NULL OR v_discarded_org IS NULL THEN 
        RAISE EXCEPTION 'Suppliers not found.'; 
    END IF;
    
    IF v_keeper_org != v_auth_org OR v_discarded_org != v_auth_org THEN 
        RAISE EXCEPTION 'Unauthorized: Tenant isolation breach detected.'; 
    END IF;

    UPDATE public.suppliers 
    SET contact_email = NULL, contact_phone = NULL, is_active = false
    WHERE id = discarded_id;

    UPDATE public.suppliers 
    SET name = merged_name, 
        contact_email = NULLIF(TRIM(merged_email), ''), 
        contact_phone = NULLIF(TRIM(merged_phone), ''), 
        category = merged_category, 
        tags = v_tags, 
        internal_docs = v_docs 
    WHERE id = keeper_id;

    UPDATE public.accommodations SET supplier_id = keeper_id WHERE supplier_id = discarded_id;
    UPDATE public.guides SET supplier_id = keeper_id WHERE supplier_id = discarded_id;
    UPDATE public.other_services SET supplier_id = keeper_id WHERE supplier_id = discarded_id;

    DELETE FROM public.transport_rates WHERE supplier_id = discarded_id AND transport_id IN (SELECT transport_id FROM public.transport_rates WHERE supplier_id = keeper_id);
    UPDATE public.transport_rates SET supplier_id = keeper_id WHERE supplier_id = discarded_id;

    DELETE FROM public.activity_rates WHERE supplier_id = discarded_id AND activity_id IN (SELECT activity_id FROM public.activity_rates WHERE supplier_id = keeper_id);
    UPDATE public.activity_rates SET supplier_id = keeper_id WHERE supplier_id = discarded_id;
END;
$$;


ALTER FUNCTION "public"."merge_suppliers_v2"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "jsonb", "merged_internal_docs" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."org_id_jwt_hook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_org_id uuid;
BEGIN
  -- Extract organization_id from the user's profile
  SELECT organization_id INTO v_org_id
  FROM public.profiles
  WHERE id = NEW.id;

  IF v_org_id IS NOT NULL THEN
    -- Inject into JWT claims as both 'org_id' (short) and 'organization_id' (backwards compat)
    NEW.raw_app_meta_data = jsonb_set(
      COALESCE(NEW.raw_app_meta_data, '{}'::jsonb),
      '{org_id}',
      to_jsonb(v_org_id::text)
    );
    NEW.raw_app_meta_data = jsonb_set(
      NEW.raw_app_meta_data,
      '{organization_id}',
      to_jsonb(v_org_id::text)
    );
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."org_id_jwt_hook"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resurrect_record"("p_table" "text", "p_record_id" "uuid", "p_organization_id" "uuid", "p_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  v_cols text;
  v_sql text;
  v_auth_org uuid;
BEGIN
  -- ============================================
  -- IDOR CHECK: La org del JWT debe coincidir con la solicitada
  -- ============================================
  v_auth_org := public.get_auth_org_id();
  IF v_auth_org IS NULL OR v_auth_org != p_organization_id THEN
    RAISE EXCEPTION 'Unauthorized: organization mismatch.'
      USING ERRCODE = 'P0001';
  END IF;

  -- Validar que la tabla está en la lista permitida (seguridad)
  IF p_table NOT IN (
    'suppliers', 'accommodations', 'activities', 'transports', 'guides',
    'other_services', 'accommodation_rooms', 'activity_rates',
    'transport_rates', 'guide_rates', 'agents', 'clients', 'consortiums',
    'locations'
  ) THEN
    RAISE EXCEPTION 'Table not allowed for resurrection: %', p_table;
  END IF;

  -- Verificar que el registro existe, pertenece a la org y está inactivo
  v_sql := format(
    'SELECT 1 FROM public.%I WHERE id = $1 AND organization_id = $2 AND is_active = false',
    p_table
  );
  EXECUTE v_sql INTO v_cols USING p_record_id, p_organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Record % not found, not owned by organization, or already active in table %', p_record_id, p_table;
  END IF;

  -- Construir SET dinámico desde p_data, excluyendo columnas del sistema
  SELECT string_agg(
    format('%I = $1->>%L', key, key),
    ', '
  )
  INTO v_cols
  FROM jsonb_object_keys(p_data) AS key
  WHERE key NOT IN ('id', 'organization_id', 'is_active', 'created_at');

  IF v_cols IS NULL THEN
    RAISE EXCEPTION 'No updatable columns provided in p_data';
  END IF;

  v_sql := format(
    'UPDATE public.%I SET is_active = true, %s WHERE id = $2 AND organization_id = $3',
    p_table, v_cols
  );

  EXECUTE v_sql USING p_data, p_record_id, p_organization_id;
END;
$_$;


ALTER FUNCTION "public"."resurrect_record"("p_table" "text", "p_record_id" "uuid", "p_organization_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_bulk_hard_delete"("p_table" "text", "p_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
    v_auth_org uuid;
    v_sql text;
BEGIN
    -- Validate table name against allowlist
    IF p_table NOT IN (
        'activities', 'accommodations', 'transports', 'guides',
        'other_services', 'suppliers', 'agents', 'clients'
    ) THEN
        RAISE EXCEPTION 'Table "%" is not allowed for bulk hard delete.', p_table
            USING ERRCODE = 'P0001';
    END IF;

    -- IDOR check
    v_auth_org := public.get_auth_org_id();
    IF v_auth_org IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: no organization context.'
            USING ERRCODE = 'P0001';
    END IF;

    -- Single atomic DELETE
    v_sql := format(
        'DELETE FROM public.%I WHERE id = ANY($1) AND organization_id = $2',
        p_table
    );
    EXECUTE v_sql USING p_ids, v_auth_org;
END;
$_$;


ALTER FUNCTION "public"."rpc_bulk_hard_delete"("p_table" "text", "p_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_bulk_insert"("p_table" "text", "p_payload" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
    v_auth_org uuid;
    v_keys text[];
    v_cols text;
    v_sql text;
    v_injected jsonb;
BEGIN
    -- Validate table name against allowlist
    IF p_table NOT IN (
        'activities', 'accommodations', 'transports', 'guides',
        'other_services', 'suppliers', 'agents', 'clients'
    ) THEN
        RAISE EXCEPTION 'Table "%" is not allowed for bulk insert.', p_table
            USING ERRCODE = 'P0001';
    END IF;

    -- IDOR check
    v_auth_org := public.get_auth_org_id();
    IF v_auth_org IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: no organization context.'
            USING ERRCODE = 'P0001';
    END IF;

    -- Validate payload
    IF p_payload IS NULL OR jsonb_typeof(p_payload) != 'array' OR jsonb_array_length(p_payload) = 0 THEN
        RAISE EXCEPTION 'Payload must be a non-empty JSON array.'
            USING ERRCODE = 'P0001';
    END IF;

    -- Extract column keys from first element
    SELECT array_agg(DISTINCT j.key) INTO v_keys
    FROM jsonb_array_elements(p_payload) AS elem,
    LATERAL jsonb_object_keys(elem) AS j(key);

    -- Inject organization_id into each element
    WITH numbered AS (
        SELECT row_number() OVER () - 1 AS idx, elem
        FROM jsonb_array_elements(p_payload) AS elem
    )
    SELECT jsonb_agg(
        elem || jsonb_build_object('organization_id', v_auth_org)
        ORDER BY idx
    ) INTO v_injected
    FROM numbered;

    -- Build dynamic INSERT with jsonb_to_recordset
    v_sql := format(
        'INSERT INTO public.%I SELECT * FROM jsonb_to_recordset($1) AS x(%s)',
        p_table,
        (SELECT string_agg(k || ' text', ', ') FROM unnest(v_keys) AS k)
    );

    EXECUTE v_sql USING v_injected;
END;
$_$;


ALTER FUNCTION "public"."rpc_bulk_insert"("p_table" "text", "p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_bulk_soft_delete"("p_table" "text", "p_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
    v_auth_org uuid;
    v_sql text;
BEGIN
    -- Validate table name against allowlist (defense against SQL injection)
    IF p_table NOT IN (
        'activities', 'accommodations', 'transports', 'guides',
        'other_services', 'suppliers', 'agents', 'clients'
    ) THEN
        RAISE EXCEPTION 'Table "%" is not allowed for bulk soft delete.', p_table
            USING ERRCODE = 'P0001';
    END IF;

    -- IDOR: ensure caller owns the organization
    v_auth_org := public.get_auth_org_id();
    IF v_auth_org IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: no organization context.'
            USING ERRCODE = 'P0001';
    END IF;

    -- Single atomic UPDATE — no chunking, no loop
    v_sql := format(
        'UPDATE public.%I SET is_active = false WHERE id = ANY($1) AND organization_id = $2',
        p_table
    );
    EXECUTE v_sql USING p_ids, v_auth_org;
END;
$_$;


ALTER FUNCTION "public"."rpc_bulk_soft_delete"("p_table" "text", "p_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_rebuild_snapshot"("p_table" "text", "p_record_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_snapshot  jsonb;
    v_it_id     uuid;
    v_frozen    boolean;
    v_currency  jsonb;
    v_base_cur  char(3);
    v_ex_rate_id uuid;
    v_ex_rate   numeric(18,8);
    v_ex_from   char(3);
    v_ex_to     char(3);
BEGIN
    -- ── 1. Resolve parent itinerary ID + frozen status ──
    CASE p_table
        WHEN 'itinerary_stays' THEN
            SELECT s.itinerary_id INTO v_it_id
            FROM public.itinerary_stays s WHERE s.id = p_record_id;
        WHEN 'itinerary_activities' THEN
            SELECT a.itinerary_id INTO v_it_id
            FROM public.itinerary_activities a WHERE a.id = p_record_id;
        WHEN 'itinerary_transports' THEN
            SELECT t.itinerary_id INTO v_it_id
            FROM public.itinerary_transports t WHERE t.id = p_record_id;
        WHEN 'itinerary_guides' THEN
            SELECT g.itinerary_id INTO v_it_id
            FROM public.itinerary_guides g WHERE g.id = p_record_id;
        ELSE
            RAISE EXCEPTION 'Unknown table: %', p_table;
    END CASE;

    IF v_it_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- ── 2. Check if itinerary is frozen ──
    SELECT (i.quote_valid_until IS NOT NULL) INTO v_frozen
    FROM public.itineraries i WHERE i.id = v_it_id;

    IF v_frozen THEN
        -- Return existing snapshot without modifying (frozen)
        CASE p_table
            WHEN 'itinerary_stays' THEN
                SELECT service_snapshot INTO v_snapshot
                FROM public.itinerary_stays WHERE id = p_record_id;
            WHEN 'itinerary_activities' THEN
                SELECT service_snapshot INTO v_snapshot
                FROM public.itinerary_activities WHERE id = p_record_id;
            WHEN 'itinerary_transports' THEN
                SELECT service_snapshot INTO v_snapshot
                FROM public.itinerary_transports WHERE id = p_record_id;
            WHEN 'itinerary_guides' THEN
                SELECT service_snapshot INTO v_snapshot
                FROM public.itinerary_guides WHERE id = p_record_id;
        END CASE;
        RETURN v_snapshot;
    END IF;

    -- ── 3. Build currency metadata ──
    SELECT i.base_currency, i.exchange_rate_id
    INTO v_base_cur, v_ex_rate_id
    FROM public.itineraries i WHERE i.id = v_it_id;

    v_currency := jsonb_build_object('base_currency', COALESCE(v_base_cur, 'USD'));

    IF v_ex_rate_id IS NOT NULL THEN
        SELECT er.rate, er.from_currency, er.to_currency
        INTO v_ex_rate, v_ex_from, v_ex_to
        FROM public.exchange_rates er WHERE er.id = v_ex_rate_id;

        v_currency := v_currency || jsonb_build_object(
            'exchange_rate_id', v_ex_rate_id,
            'exchange_rate', v_ex_rate,
            'exchange_from', v_ex_from,
            'exchange_to', v_ex_to
        );
    END IF;

    -- ── 4. Build snapshot ──
    CASE p_table
        WHEN 'itinerary_stays' THEN
            v_snapshot := public.build_stay_service_snapshot(p_record_id);
            UPDATE public.itinerary_stays
            SET service_snapshot = v_snapshot || v_currency
            WHERE id = p_record_id;
        WHEN 'itinerary_activities' THEN
            v_snapshot := public.build_activity_service_snapshot(p_record_id);
            UPDATE public.itinerary_activities
            SET service_snapshot = v_snapshot || v_currency
            WHERE id = p_record_id;
        WHEN 'itinerary_transports' THEN
            v_snapshot := public.build_transport_service_snapshot(p_record_id);
            UPDATE public.itinerary_transports
            SET service_snapshot = v_snapshot || v_currency
            WHERE id = p_record_id;
        WHEN 'itinerary_guides' THEN
            v_snapshot := public.build_guide_service_snapshot(p_record_id);
            UPDATE public.itinerary_guides
            SET service_snapshot = v_snapshot || v_currency
            WHERE id = p_record_id;
    END CASE;

    RETURN v_snapshot || v_currency;
END;
$$;


ALTER FUNCTION "public"."rpc_rebuild_snapshot"("p_table" "text", "p_record_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rpc_rebuild_snapshot"("p_table" "text", "p_record_id" "uuid") IS 'Rebuilds service_snapshot for a single bridge record. Skips if itinerary is frozen (quote_valid_until IS NOT NULL). Injects currency metadata.';



CREATE OR REPLACE FUNCTION "public"."sync_stay_rooms"("p_stay_id" "uuid", "p_rooms" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_org_id uuid;
    v_auth_org uuid;
BEGIN
    -- Resolve org from stay
    SELECT s.organization_id INTO v_org_id
    FROM public.itinerary_stays s
    WHERE s.id = p_stay_id;

    IF v_org_id IS NULL THEN
        RAISE EXCEPTION 'Stay not found: %', p_stay_id;
    END IF;

    -- IDOR check
    v_auth_org := public.get_auth_org_id();
    IF v_auth_org IS NULL OR v_auth_org != v_org_id THEN
        RAISE EXCEPTION 'Unauthorized: organization mismatch.'
            USING ERRCODE = 'P0001';
    END IF;

    -- Step 1: Delete rooms NOT in the incoming payload
    DELETE FROM public.stay_rooms
    WHERE stay_id = p_stay_id
      AND (p_rooms IS NULL OR jsonb_array_length(p_rooms) = 0
           OR id NOT IN (
               SELECT (value->>'id')::uuid
               FROM jsonb_array_elements(p_rooms)
               WHERE value->>'id' IS NOT NULL
           ));

    IF p_rooms IS NULL OR jsonb_array_length(p_rooms) = 0 THEN
        RETURN;
    END IF;

    -- Step 2: Upsert — single atomic INSERT ... ON CONFLICT DO UPDATE
    INSERT INTO public.stay_rooms (
        id, stay_id, room_id, pax_per_room, quantity,
        selected_supplier_rate_id, sell_price_per_night,
        total_room_cost, organization_id, calculated_by
    )
    SELECT
        COALESCE((v_room->>'id')::uuid, gen_random_uuid()),
        p_stay_id,
        (v_room->>'room_id')::uuid,
        (v_room->>'pax_per_room')::integer,
        COALESCE((v_room->>'quantity')::integer, 1),
        (v_room->>'selected_supplier_rate_id')::uuid,
        COALESCE((v_room->>'sell_price_per_night')::numeric, 0),
        COALESCE((v_room->>'total_room_cost')::numeric, 0),
        v_org_id,
        (v_room->>'calculated_by')::uuid
    FROM jsonb_array_elements(p_rooms) AS v_room
    ON CONFLICT (id) DO UPDATE SET
        room_id = EXCLUDED.room_id,
        pax_per_room = EXCLUDED.pax_per_room,
        quantity = EXCLUDED.quantity,
        selected_supplier_rate_id = EXCLUDED.selected_supplier_rate_id,
        sell_price_per_night = EXCLUDED.sell_price_per_night,
        total_room_cost = EXCLUDED.total_room_cost,
        calculated_by = EXCLUDED.calculated_by;
END;
$$;


ALTER FUNCTION "public"."sync_stay_rooms"("p_stay_id" "uuid", "p_rooms" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_activity"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.activity_id IS NOT NULL THEN
    SELECT a.name INTO NEW.snapshot_activity_name
    FROM public.activities a
    WHERE a.id = NEW.activity_id;
  END IF;

  IF NEW.selected_supplier_rate_id IS NOT NULL THEN
    SELECT ar.base_cost, s.name
    INTO NEW.snapshot_unit_cost, NEW.snapshot_supplier_name
    FROM public.activity_rates ar
    JOIN public.suppliers s ON s.id = ar.supplier_id
    WHERE ar.id = NEW.selected_supplier_rate_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_activity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_activity_component"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.activity_rate_id IS NOT NULL THEN
    SELECT ar.name, ar.base_cost
    INTO NEW.snapshot_rate_name, NEW.snapshot_unit_cost
    FROM public.activity_rates ar
    WHERE ar.id = NEW.activity_rate_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_activity_component"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_guide"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.guide_id IS NOT NULL THEN
    SELECT g.name INTO NEW.snapshot_guide_name
    FROM public.guides g
    WHERE g.id = NEW.guide_id;
  END IF;

  IF NEW.selected_rate_id IS NOT NULL THEN
    SELECT gr.price INTO NEW.snapshot_unit_cost
    FROM public.guide_rates gr
    WHERE gr.id = NEW.selected_rate_id;
  END IF;

  IF NEW.selected_rate_id IS NOT NULL THEN
    SELECT s.name INTO NEW.snapshot_supplier_name
    FROM public.guide_rates gr
    JOIN public.guides g ON g.id = gr.guide_id
    JOIN public.suppliers s ON s.id = g.supplier_id
    WHERE gr.id = NEW.selected_rate_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_guide"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_guide_segment"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.guide_rate_id IS NOT NULL THEN
    SELECT gr.name, gr.price
    INTO NEW.snapshot_segment_name, NEW.snapshot_unit_cost
    FROM public.guide_rates gr
    WHERE gr.id = NEW.guide_rate_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_guide_segment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_itinerary"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.agent_id IS NOT NULL THEN
    SELECT g.agency_name INTO NEW.snapshot_agent_name
    FROM public.agents g
    WHERE g.id = NEW.agent_id;
  ELSE
    NEW.snapshot_agent_name = NULL;
  END IF;

  IF NEW.consortium_id IS NOT NULL THEN
    SELECT c.name INTO NEW.snapshot_consortium_name
    FROM public.consortiums c
    WHERE c.id = NEW.consortium_id;
  ELSE
    NEW.snapshot_consortium_name = NULL;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_itinerary"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_itinerary_pax"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.client_id IS NOT NULL THEN
    SELECT CONCAT(TRIM(c.first_name), ' ', TRIM(COALESCE(c.last_name, '')))
    INTO NEW.snapshot_client_name
    FROM public.clients c
    WHERE c.id = NEW.client_id;
  ELSE
    NEW.snapshot_client_name = NULL;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_itinerary_pax"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_other_service"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.service_id IS NOT NULL THEN
    SELECT os.name, os.default_price, s.name
    INTO NEW.snapshot_service_name, NEW.snapshot_unit_cost, NEW.snapshot_supplier_name
    FROM public.other_services os
    JOIN public.suppliers s ON s.id = os.supplier_id
    WHERE os.id = NEW.service_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_other_service"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_stay"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.accommodation_id IS NOT NULL THEN
    SELECT a.name, s.name
    INTO NEW.snapshot_accommodation_name, NEW.snapshot_supplier_name
    FROM public.accommodations a
    LEFT JOIN public.suppliers s ON s.id = a.supplier_id
    WHERE a.id = NEW.accommodation_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_stay"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_stay_room"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_acc_id uuid;
BEGIN
  IF NEW.room_id IS NOT NULL THEN
    SELECT r.name, COALESCE(r.rate_high, 0)
    INTO NEW.snapshot_room_name, NEW.snapshot_unit_cost
    FROM public.accommodation_rooms r
    WHERE r.id = NEW.room_id;

    SELECT a.supplier_id INTO v_acc_id
    FROM public.accommodation_rooms ar
    JOIN public.accommodations a ON a.id = ar.accommodation_id
    WHERE ar.id = NEW.room_id;

    IF v_acc_id IS NOT NULL THEN
      SELECT s.name INTO NEW.snapshot_supplier_name
      FROM public.suppliers s
      WHERE s.id = v_acc_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_stay_room"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fill_snapshot_transport"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.transport_id IS NOT NULL THEN
    SELECT t.name INTO NEW.snapshot_transport_name
    FROM public.transports t
    WHERE t.id = NEW.transport_id;
  END IF;

  IF NEW.selected_supplier_rate_id IS NOT NULL THEN
    SELECT tr.cost, s.name
    INTO NEW.snapshot_unit_cost, NEW.snapshot_supplier_name
    FROM public.transport_rates tr
    JOIN public.suppliers s ON s.id = tr.supplier_id
    WHERE tr.id = NEW.selected_supplier_rate_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fill_snapshot_transport"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_soft_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
BEGIN
    -- Convert DELETE into a soft-delete UPDATE
    -- We must use a separate UPDATE because we cannot set NEW.deleted_at
    -- in a BEFORE DELETE trigger (the row is being deleted).
    EXECUTE format('UPDATE %s SET deleted_at = now() WHERE id = $1', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME)
    USING OLD.id;
    -- Return NULL to abort the original DELETE
    RETURN NULL;
END;
$_$;


ALTER FUNCTION "public"."trg_soft_delete"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."trg_soft_delete"() IS 'Generic BEFORE DELETE trigger function: converts DELETE into soft-delete (SET deleted_at = now()) and returns NULL to abort the physical DELETE. Applied to all Shell and Rate tables to preserve FK integrity.';



CREATE OR REPLACE FUNCTION "public"."update_exchange_rate_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_exchange_rate_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_guide_rate_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_guide_rate_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_itinerary_items_positions"("p_updates" "jsonb", "p_itinerary_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  update_record RECORD;
  updated_count INT := 0;
BEGIN
  -- First pass: negate positions to avoid unique constraint violations
  FOR update_record IN 
    SELECT * FROM jsonb_to_recordset(p_updates) AS x(id UUID, position INT)
  LOOP
    UPDATE itinerary_items 
    SET position = -1 * abs((random() * 1000000)::int) - update_record.position
    WHERE id = update_record.id 
      AND itinerary_id = p_itinerary_id;
  END LOOP;
  
  -- Second pass: set to actual positions
  FOR update_record IN 
    SELECT * FROM jsonb_to_recordset(p_updates) AS x(id UUID, position INT)
  LOOP
    UPDATE itinerary_items 
    SET position = update_record.position
    WHERE id = update_record.id 
      AND itinerary_id = p_itinerary_id;
    
    IF FOUND THEN
      updated_count := updated_count + 1;
    END IF;
  END LOOP;
  
  RETURN 'Updated ' || updated_count || ' items';
END;
$$;


ALTER FUNCTION "public"."update_itinerary_items_positions"("p_updates" "jsonb", "p_itinerary_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_other_service_rate_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_other_service_rate_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_team_member_role"("p_user_id" "uuid", "p_new_role" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_caller_role text;
    v_caller_org uuid;
    v_target_org uuid;
BEGIN
    -- 1. Obtener datos del admin que hace la petición
    SELECT role, organization_id INTO v_caller_role, v_caller_org 
    FROM public.profiles 
    WHERE id = auth.uid();

    -- 2. Obtener organización del usuario a modificar
    SELECT organization_id INTO v_target_org 
    FROM public.profiles 
    WHERE id = p_user_id;

    -- 3. Sello de Seguridad: Debe ser ADMIN y del mismo tenant
    IF v_caller_role != 'ADMIN' OR v_caller_org != v_target_org THEN
        RAISE EXCEPTION 'Unauthorized: Only Admins can modify roles within their organization.';
    END IF;

    -- 4. Ejecutar actualización
    UPDATE public.profiles 
    SET role = p_new_role 
    WHERE id = p_user_id;
END;
$$;


ALTER FUNCTION "public"."update_team_member_role"("p_user_id" "uuid", "p_new_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_catalog_price"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_catalog_price numeric;
BEGIN
  -- Solo validamos itinerary_other_services por ahora
  IF TG_TABLE_NAME = 'itinerary_other_services' THEN
    -- Si hay manual_cost_override, el trigger validate_price_override ya valida
    -- rate_justification. No bloqueamos el precio.
    IF NEW.manual_cost_override IS NOT NULL THEN
      RETURN NEW;
    END IF;

    -- Obtener el precio del catálogo
    SELECT default_price INTO v_catalog_price
    FROM public.other_services
    WHERE id = NEW.service_id AND organization_id = NEW.organization_id;

    -- Si existe precio en catálogo, validar que coincida
    IF v_catalog_price IS NOT NULL AND NEW.unit_price IS DISTINCT FROM v_catalog_price THEN
      RAISE EXCEPTION 'Price mismatch: unit_price (%) does not match catalog price (%) for service %. Use manual_cost_override with a justification to override.',
        NEW.unit_price, v_catalog_price, NEW.service_id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_catalog_price"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_price_override"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_old_price numeric;
  v_itinerary_id uuid;
  v_item_type text;
BEGIN
  -- Solo nos interesa cuando manual_cost_override cambia
  IF TG_OP = 'UPDATE' AND (OLD.manual_cost_override IS NOT DISTINCT FROM NEW.manual_cost_override) THEN
    RETURN NEW;
  END IF;

  -- Si se está estableciendo un override, rate_justification es obligatoria
  IF NEW.manual_cost_override IS NOT NULL THEN
    IF NEW.rate_justification IS NULL OR TRIM(NEW.rate_justification) = '' THEN
      RAISE EXCEPTION 'Rate justification is required when setting a manual cost override. Please provide a reason in the rate_justification field.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- Determinar el itinerary_id y item_type según la tabla
  CASE TG_TABLE_NAME
    WHEN 'itinerary_activities' THEN
      v_itinerary_id := NEW.itinerary_id;
      v_item_type := 'ACTIVITY';
      v_old_price := COALESCE(OLD.manual_cost_override, 0);
    WHEN 'itinerary_transports' THEN
      v_itinerary_id := NEW.itinerary_id;
      v_item_type := 'TRANSPORT';
      v_old_price := COALESCE(OLD.manual_cost_override, 0);
    WHEN 'stay_rooms' THEN
      SELECT s.itinerary_id INTO v_itinerary_id
      FROM public.itinerary_stays s
      WHERE s.id = NEW.stay_id;
      v_item_type := 'ROOM';
      v_old_price := COALESCE(OLD.manual_cost_override, OLD.sell_price_per_night);
    WHEN 'itinerary_guides' THEN
      v_itinerary_id := NEW.itinerary_id;
      v_item_type := 'GUIDE';
      v_old_price := COALESCE(OLD.manual_cost_override, OLD.total_price);
    WHEN 'itinerary_other_services' THEN
      v_itinerary_id := NEW.itinerary_id;
      v_item_type := 'OTHER_SERVICE';
      v_old_price := COALESCE(OLD.manual_cost_override, OLD.total_price);
    ELSE
      RAISE EXCEPTION 'Unsupported table: %', TG_TABLE_NAME;
  END CASE;

  -- Si hay override y es diferente del anterior, registrar en audit log
  IF NEW.manual_cost_override IS NOT NULL THEN
    INSERT INTO public.price_override_logs (
      organization_id,
      itinerary_id,
      item_type,
      item_id,
      user_id,
      old_price,
      new_price,
      reason_note
    ) VALUES (
      COALESCE(NEW.organization_id, (SELECT organization_id FROM public.itineraries WHERE id = v_itinerary_id)),
      v_itinerary_id,
      v_item_type,
      NEW.id,
      COALESCE(
        NEW.calculated_by,
        (SELECT id FROM public.profiles WHERE id = auth.uid() LIMIT 1),
        '00000000-0000-0000-0000-000000000000'::uuid
      ),
      v_old_price,
      NEW.manual_cost_override,
      NEW.rate_justification
    );
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_price_override"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."accommodation_room_rates" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "room_id" "uuid" NOT NULL,
    "season_id" "uuid" NOT NULL,
    "rate" numeric NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "local_currency_note" "text",
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "currency_code" character(3) DEFAULT 'USD'::"bpchar" NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."accommodation_room_rates" OWNER TO "postgres";


COMMENT ON COLUMN "public"."accommodation_room_rates"."currency_code" IS 'ISO 4217 currency code for this rate.';



COMMENT ON COLUMN "public"."accommodation_room_rates"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."accommodation_rooms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "accommodation_id" "uuid",
    "name" "text" NOT NULL,
    "capacity_pax" integer DEFAULT 2,
    "rate_high" numeric(10,2) DEFAULT 0 NOT NULL,
    "rate_low" numeric DEFAULT '0'::numeric,
    "images" "text"[] DEFAULT '{}'::"text"[],
    "is_active" boolean DEFAULT true NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."accommodation_rooms" OWNER TO "postgres";


COMMENT ON COLUMN "public"."accommodation_rooms"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."accommodation_seasons" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "accommodation_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."accommodation_seasons" OWNER TO "postgres";


COMMENT ON COLUMN "public"."accommodation_seasons"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."accommodations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "supplier_id" "uuid",
    "name" "text" NOT NULL,
    "address" "text",
    "description" "text",
    "check_in_time" time without time zone,
    "check_out_time" time without time zone,
    "cancellation_policy" "text",
    "buyout_price" numeric(10,2),
    "images" "text"[] DEFAULT '{}'::"text"[],
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "location_id" "uuid",
    "is_active" boolean DEFAULT true NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."accommodations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."accommodations"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "name" "text" NOT NULL,
    "description" "text",
    "images" "text"[] DEFAULT '{}'::"text"[],
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "location_id" "uuid",
    "category" "text" DEFAULT 'TOUR'::"text",
    "is_active" boolean DEFAULT true NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."activities" OWNER TO "postgres";


COMMENT ON COLUMN "public"."activities"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."activity_rates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "activity_id" "uuid" NOT NULL,
    "supplier_id" "uuid" NOT NULL,
    "pricing_model" "text" DEFAULT 'PER_PAX'::"text",
    "base_cost" numeric(10,2) DEFAULT 0,
    "base_pax_included" integer DEFAULT 0,
    "extra_pax_cost" numeric(10,2) DEFAULT 0,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "max_capacity" integer,
    "local_currency_note" "text",
    "name" "text",
    "is_component" boolean DEFAULT false,
    "is_active" boolean DEFAULT true NOT NULL,
    "currency_code" character(3) DEFAULT 'USD'::"bpchar" NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."activity_rates" OWNER TO "postgres";


COMMENT ON COLUMN "public"."activity_rates"."currency_code" IS 'ISO 4217 currency code for this rate.';



COMMENT ON COLUMN "public"."activity_rates"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."agents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "agency_name" "text" NOT NULL,
    "contact_name" "text",
    "email" "text",
    "default_commission_percent" numeric(5,2) DEFAULT 10.00,
    "associated_consortium_id" "uuid",
    "phone" "text",
    "website" "text",
    "logo_url" "text",
    "banking_info" "text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "is_active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."agents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "first_name" "text" NOT NULL,
    "last_name" "text",
    "email" "text",
    "passport_number" "text",
    "nationality" "text",
    "notes" "text",
    "referred_by_agent_id" "uuid",
    "phone" "text",
    "dob" "date",
    "gender" "text",
    "dietary_restrictions" "text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "is_active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."clients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."consortiums" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "name" "text" NOT NULL,
    "default_fee_percent" numeric(5,2) DEFAULT 0,
    "is_active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."consortiums" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."exchange_rates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"() NOT NULL,
    "from_currency" character(3) NOT NULL,
    "to_currency" character(3) NOT NULL,
    "rate" numeric(18,8) NOT NULL,
    "valid_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "valid_until" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "exchange_rates_currencies_check" CHECK (("from_currency" <> "to_currency")),
    CONSTRAINT "exchange_rates_unique_pair" CHECK ((("organization_id" IS NOT NULL) AND ("from_currency" IS NOT NULL) AND ("to_currency" IS NOT NULL)))
);


ALTER TABLE "public"."exchange_rates" OWNER TO "postgres";


COMMENT ON TABLE "public"."exchange_rates" IS 'Exchange rates for multi-currency quoting. Rates are per-organization.';



COMMENT ON COLUMN "public"."exchange_rates"."rate" IS 'Conversion rate: 1 from_currency = N to_currency';



COMMENT ON COLUMN "public"."exchange_rates"."valid_from" IS 'Start of validity period for this rate.';



COMMENT ON COLUMN "public"."exchange_rates"."valid_until" IS 'End of validity period. NULL = still current.';



CREATE TABLE IF NOT EXISTS "public"."global_cities" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "asciiname" "text",
    "alternatenames" "text",
    "latitude" "text",
    "longitude" "text",
    "country_code" character varying(2),
    "population" bigint
);


ALTER TABLE "public"."global_cities" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."global_cities_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."global_cities_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."global_cities_id_seq" OWNED BY "public"."global_cities"."id";



CREATE TABLE IF NOT EXISTS "public"."guide_rates" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "guide_id" "uuid",
    "name" "text" NOT NULL,
    "price" numeric(10,2) DEFAULT 0 NOT NULL,
    "local_currency_note" "text",
    "organization_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true NOT NULL,
    "pricing_model" "text" DEFAULT 'FIXED'::"text" NOT NULL,
    "base_cost" numeric(10,2) DEFAULT 0,
    "max_capacity" integer,
    "notes" "text",
    "currency_code" character(3) DEFAULT 'USD'::"bpchar" NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "guide_rates_pricing_model_check" CHECK (("pricing_model" = ANY (ARRAY['FIXED'::"text", 'PER_PAX'::"text"])))
);


ALTER TABLE "public"."guide_rates" OWNER TO "postgres";


COMMENT ON TABLE "public"."guide_rates" IS 'Rates for guides, matching the Shell+Rates pattern of activity_rates, transport_rates, etc.';



COMMENT ON COLUMN "public"."guide_rates"."currency_code" IS 'ISO 4217 currency code for this rate.';



COMMENT ON COLUMN "public"."guide_rates"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."guides" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "supplier_id" "uuid",
    "name" "text" NOT NULL,
    "languages" "text"[],
    "phone" "text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "location_id" "uuid",
    "is_freelance" boolean DEFAULT true,
    "email" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."guides" OWNER TO "postgres";


COMMENT ON COLUMN "public"."guides"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE SEQUENCE IF NOT EXISTS "public"."itinerary_ref_seq"
    START WITH 1000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."itinerary_ref_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itineraries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "reference_code" "text" DEFAULT (("to_char"((CURRENT_DATE)::timestamp with time zone, 'YY'::"text") || '-'::"text") || "nextval"('"public"."itinerary_ref_seq"'::"regclass")),
    "title" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text",
    "start_date" "date",
    "duration_days" integer DEFAULT 1,
    "budget_target" numeric,
    "requirements_summary" "text",
    "agent_id" "uuid",
    "consortium_id" "uuid",
    "pax_count" integer DEFAULT 1,
    "trip_leaders_count" integer DEFAULT 0,
    "is_template" boolean DEFAULT false,
    "agent_commission_percent" numeric DEFAULT 0,
    "overhead_percent" numeric DEFAULT 0,
    "markup_percent" numeric DEFAULT 0,
    "price_adjustment" numeric DEFAULT 0,
    "consortium_commission_percent" numeric,
    "tier" "public"."itinerary_tier" DEFAULT 'STANDARD'::"public"."itinerary_tier",
    "manual_markup_rule_id" "uuid",
    "manual_overhead_rule_id" "uuid",
    "manual_markup_amount" numeric,
    "manual_overhead_amount" numeric,
    "client_request_text" "text",
    "request_analysis" "jsonb",
    "net_total" numeric DEFAULT 0,
    "gross_total" numeric DEFAULT 0,
    "manual_paying_paxes" integer,
    "assigned_to" "uuid",
    "assigned_to_profile" "uuid",
    "snapshot_agent_name" "text",
    "snapshot_consortium_name" "text",
    "base_currency" character(3) DEFAULT 'USD'::"bpchar" NOT NULL,
    "quote_valid_until" timestamp with time zone,
    "exchange_rate_id" "uuid",
    "quote_sent_at" timestamp with time zone
);


ALTER TABLE "public"."itineraries" OWNER TO "postgres";


COMMENT ON COLUMN "public"."itineraries"."base_currency" IS 'ISO 4217 currency code for this itinerary''s quote (e.g., USD, EUR, MXN).';



COMMENT ON COLUMN "public"."itineraries"."quote_valid_until" IS 'Date until which the quote price is guaranteed. NULL = no expiration.';



COMMENT ON COLUMN "public"."itineraries"."exchange_rate_id" IS 'The exchange rate used when this quote was frozen/sent. NULL if quoting in base currency.';



COMMENT ON COLUMN "public"."itineraries"."quote_sent_at" IS 'Timestamp when the quote was sent to the client. NULL if still in draft.';



CREATE TABLE IF NOT EXISTS "public"."itinerary_activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "itinerary_id" "uuid" NOT NULL,
    "activity_id" "uuid" NOT NULL,
    "selected_supplier_rate_id" "uuid",
    "manual_cost_override" numeric,
    "rate_justification" "text",
    "calculated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "snapshot_activity_name" "text",
    "snapshot_supplier_name" "text",
    "snapshot_unit_cost" numeric(10,2),
    "service_snapshot" "jsonb"
);


ALTER TABLE "public"."itinerary_activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_activity_components" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "itinerary_activity_id" "uuid",
    "activity_rate_id" "uuid",
    "quantity" numeric(10,2) DEFAULT 1,
    "custom_price" numeric(10,2),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "snapshot_rate_name" "text",
    "snapshot_unit_cost" numeric(10,2)
);


ALTER TABLE "public"."itinerary_activity_components" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_guide_segments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_guide_id" "uuid" NOT NULL,
    "guide_rate_id" "uuid",
    "name" "text" NOT NULL,
    "quantity" integer DEFAULT 1,
    "sell_price" numeric(10,2) DEFAULT 0 NOT NULL,
    "total_price" numeric(10,2) DEFAULT 0 NOT NULL,
    "calculated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "snapshot_segment_name" "text",
    "snapshot_unit_cost" numeric(10,2)
);


ALTER TABLE "public"."itinerary_guide_segments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_guides" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_id" "uuid",
    "guide_id" "uuid",
    "start_day" integer NOT NULL,
    "end_day" integer NOT NULL,
    "total_price" numeric(10,2) NOT NULL,
    "notes" "text",
    "calculated_by" "uuid",
    "rate_justification" "text",
    "manual_cost_override" numeric,
    "selected_rate_id" "uuid",
    "snapshot_guide_name" "text",
    "snapshot_supplier_name" "text",
    "snapshot_unit_cost" numeric(10,2),
    "service_snapshot" "jsonb"
);


ALTER TABLE "public"."itinerary_guides" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_id" "uuid",
    "activity_id" "uuid",
    "day_number" integer NOT NULL,
    "start_time" time without time zone,
    "quantity" integer DEFAULT 1,
    "unit_price" numeric(10,2) NOT NULL,
    "total_price" numeric(10,2) NOT NULL,
    "notes" "text",
    "calculated_by" "uuid",
    "rate_justification" "text",
    "position" integer DEFAULT 0 NOT NULL,
    "item_type" "text" DEFAULT 'activity'::"text" NOT NULL,
    "stay_id" "uuid",
    "itinerary_transport_id" "uuid",
    "itinerary_activity_id" "uuid",
    "itinerary_guide_id" "uuid",
    "snapshot_service_name" "text"
);


ALTER TABLE "public"."itinerary_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "itinerary_id" "uuid" NOT NULL,
    "note_type" "text" DEFAULT 'comment'::"text",
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "organization_id" "uuid" DEFAULT "public"."get_org_id"()
);


ALTER TABLE "public"."itinerary_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_other_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_id" "uuid",
    "service_id" "uuid",
    "day_number" integer,
    "quantity" integer DEFAULT 1,
    "unit_price" numeric(10,2) NOT NULL,
    "total_price" numeric(10,2) NOT NULL,
    "notes" "text",
    "calculated_by" "uuid",
    "rate_justification" "text",
    "snapshot_service_name" "text",
    "snapshot_supplier_name" "text",
    "snapshot_unit_cost" numeric(10,2),
    "manual_cost_override" numeric
);


ALTER TABLE "public"."itinerary_other_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_pax" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_id" "uuid",
    "client_id" "uuid",
    "is_lead_pax" boolean DEFAULT false,
    "rooming_notes" "text",
    "snapshot_client_name" "text"
);


ALTER TABLE "public"."itinerary_pax" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_requirements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_id" "uuid",
    "description" "text" NOT NULL,
    "is_fulfilled" boolean DEFAULT false
);


ALTER TABLE "public"."itinerary_requirements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_stays" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_id" "uuid",
    "accommodation_id" "uuid",
    "start_day" integer NOT NULL,
    "end_day" integer NOT NULL,
    "notes" "text",
    "check_in_time" time without time zone,
    "check_out_time" time without time zone,
    "snapshot_accommodation_name" "text",
    "snapshot_supplier_name" "text",
    "service_snapshot" "jsonb"
);


ALTER TABLE "public"."itinerary_stays" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_transports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_id" "uuid",
    "transport_id" "uuid",
    "start_day" integer NOT NULL,
    "end_day" integer NOT NULL,
    "pickup_time" time without time zone,
    "pickup_location" "text",
    "dropoff_location" "text",
    "flight_number" "text",
    "quantity" integer DEFAULT 1,
    "sell_price_total" numeric(10,2) DEFAULT '0'::numeric NOT NULL,
    "notes" "text",
    "calculated_by" "uuid",
    "rate_justification" "text",
    "selected_supplier_rate_id" "uuid",
    "manual_cost_override" numeric,
    "snapshot_transport_name" "text",
    "snapshot_supplier_name" "text",
    "snapshot_unit_cost" numeric(10,2),
    "service_snapshot" "jsonb"
);


ALTER TABLE "public"."itinerary_transports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "cover_image" "text",
    "aliases" "text"[] DEFAULT '{}'::"text"[],
    "country_code" character varying(2),
    "is_active" boolean DEFAULT true NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."locations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."locations"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."markup_conditions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rule_id" "uuid" NOT NULL,
    "field" "public"."markup_condition_field" NOT NULL,
    "operator" "public"."markup_condition_operator" NOT NULL,
    "value_1" "text" NOT NULL,
    "value_2" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"()
);


ALTER TABLE "public"."markup_conditions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."markup_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "agent_id" "uuid",
    "name" "text" NOT NULL,
    "rule_type" "public"."markup_rule_type" NOT NULL,
    "action_type" "public"."markup_action_type" NOT NULL,
    "action_value" numeric(15,2) NOT NULL,
    "priority" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."markup_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."organization_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "role" "text" DEFAULT 'OPERATOR'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "used" boolean DEFAULT false
);


ALTER TABLE "public"."organization_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."organizations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "name" "text" NOT NULL,
    "plan" "text" DEFAULT 'free'::"text",
    "subscription_status" "text" DEFAULT 'trialing'::"text",
    "trial_ends_at" timestamp with time zone DEFAULT ("now"() + '7 days'::interval),
    "subscription_ends_at" timestamp with time zone,
    "logo_url" "text"
);


ALTER TABLE "public"."organizations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."other_service_rates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"() NOT NULL,
    "other_service_id" "uuid" NOT NULL,
    "supplier_id" "uuid" NOT NULL,
    "name" "text" DEFAULT 'Standard Rate'::"text" NOT NULL,
    "pricing_model" "text" DEFAULT 'FIXED'::"text" NOT NULL,
    "base_cost" numeric DEFAULT 0 NOT NULL,
    "max_capacity" integer,
    "local_currency_note" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "currency_code" character(3) DEFAULT 'USD'::"bpchar" NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "other_service_rates_pricing_model_check" CHECK (("pricing_model" = ANY (ARRAY['FIXED'::"text", 'PER_PAX'::"text"])))
);


ALTER TABLE "public"."other_service_rates" OWNER TO "postgres";


COMMENT ON TABLE "public"."other_service_rates" IS 'Rates for other services, linked to suppliers — matching the pattern of activity_rates, transport_rates, etc.';



COMMENT ON COLUMN "public"."other_service_rates"."currency_code" IS 'ISO 4217 currency code for this rate.';



COMMENT ON COLUMN "public"."other_service_rates"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."other_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "supplier_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text",
    "images" "text"[],
    "tags" "text"[],
    "local_currency_note" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "location_id" "uuid",
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."other_services" OWNER TO "postgres";


COMMENT ON COLUMN "public"."other_services"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."price_override_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "itinerary_id" "uuid" NOT NULL,
    "item_type" "text" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "old_price" numeric NOT NULL,
    "new_price" numeric NOT NULL,
    "reason_note" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "price_override_logs_item_type_check" CHECK (("item_type" = ANY (ARRAY['ACTIVITY'::"text", 'ROOM'::"text", 'TRANSPORT'::"text", 'GUIDE'::"text", 'OTHER_SERVICE'::"text"])))
);


ALTER TABLE "public"."price_override_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "email" "text",
    "role" "text" DEFAULT 'operator'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "avatar_url" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stay_rooms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "stay_id" "uuid",
    "room_id" "uuid",
    "quantity" integer DEFAULT 1,
    "sell_price_per_night" numeric(10,2) NOT NULL,
    "total_room_cost" numeric(10,2) NOT NULL,
    "calculated_by" "uuid",
    "rate_justification" "text",
    "selected_supplier_rate_id" "uuid",
    "manual_cost_override" numeric,
    "pax_per_room" integer DEFAULT 2,
    "snapshot_room_name" "text",
    "snapshot_unit_cost" numeric(10,2),
    "snapshot_supplier_name" "text"
);


ALTER TABLE "public"."stay_rooms" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."suppliers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "name" "text" NOT NULL,
    "category" "text",
    "contact_email" "text",
    "contact_phone" "text",
    "logo_url" "text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "internal_docs" "text"[] DEFAULT '{}'::"text"[],
    "service_types" "text"[] DEFAULT '{}'::"text"[],
    "is_active" boolean DEFAULT true NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."suppliers" OWNER TO "postgres";


COMMENT ON COLUMN "public"."suppliers"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."transport_rates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "transport_id" "uuid" NOT NULL,
    "supplier_id" "uuid" NOT NULL,
    "cost" numeric(10,2) DEFAULT 0,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "fuel_policy" "text",
    "cost_out_city" numeric DEFAULT 0,
    "location_id" "uuid",
    "local_currency_note" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "currency_code" character(3) DEFAULT 'USD'::"bpchar" NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."transport_rates" OWNER TO "postgres";


COMMENT ON COLUMN "public"."transport_rates"."cost" IS 'Polymorphic: Total price if TRANSFER. In-city daily rate if DISPOSAL.';



COMMENT ON COLUMN "public"."transport_rates"."cost_out_city" IS 'Only used for DISPOSAL: Daily rate when sleeping outside the base city.';



COMMENT ON COLUMN "public"."transport_rates"."currency_code" IS 'ISO 4217 currency code for this rate.';



COMMENT ON COLUMN "public"."transport_rates"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



CREATE TABLE IF NOT EXISTS "public"."transports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" DEFAULT "public"."get_org_id"(),
    "service_type" "text" NOT NULL,
    "name" "text" NOT NULL,
    "origin" "text",
    "destination" "text",
    "vehicle_type" "text" NOT NULL,
    "pax_capacity" integer DEFAULT 4 NOT NULL,
    "notes" "text",
    "images" "text"[] DEFAULT '{}'::"text"[],
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "origin_id" "uuid",
    "destination_id" "uuid",
    "route_description" "text",
    "is_bidirectional" boolean DEFAULT false,
    "return_route_id" "uuid",
    "via_locations" "uuid"[] DEFAULT '{}'::"uuid"[],
    "is_active" boolean DEFAULT true NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "transports_service_type_check" CHECK (("service_type" = ANY (ARRAY['TRANSFER'::"text", 'DISPOSAL'::"text", 'FLIGHT'::"text"])))
);


ALTER TABLE "public"."transports" OWNER TO "postgres";


COMMENT ON COLUMN "public"."transports"."deleted_at" IS 'Soft-delete timestamp. NULL = active.';



ALTER TABLE ONLY "public"."global_cities" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."global_cities_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."accommodation_room_rates"
    ADD CONSTRAINT "accommodation_room_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."accommodation_room_rates"
    ADD CONSTRAINT "accommodation_room_rates_room_id_season_id_key" UNIQUE ("room_id", "season_id");



ALTER TABLE ONLY "public"."accommodation_rooms"
    ADD CONSTRAINT "accommodation_rooms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."accommodation_seasons"
    ADD CONSTRAINT "accommodation_seasons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."accommodations"
    ADD CONSTRAINT "accommodations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activity_rates"
    ADD CONSTRAINT "activity_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activity_rates"
    ADD CONSTRAINT "activity_rates_unique_variant_name_per_supplier" UNIQUE ("activity_id", "supplier_id", "name");



ALTER TABLE ONLY "public"."agents"
    ADD CONSTRAINT "agents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."consortiums"
    ADD CONSTRAINT "consortiums_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."exchange_rates"
    ADD CONSTRAINT "exchange_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."global_cities"
    ADD CONSTRAINT "global_cities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."guide_rates"
    ADD CONSTRAINT "guide_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."guides"
    ADD CONSTRAINT "guides_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_activities"
    ADD CONSTRAINT "itinerary_activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_activity_components"
    ADD CONSTRAINT "itinerary_activity_components_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_guide_segments"
    ADD CONSTRAINT "itinerary_guide_segments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_guides"
    ADD CONSTRAINT "itinerary_guides_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_notes"
    ADD CONSTRAINT "itinerary_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_other_services"
    ADD CONSTRAINT "itinerary_other_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_pax"
    ADD CONSTRAINT "itinerary_pax_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_requirements"
    ADD CONSTRAINT "itinerary_requirements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_stays"
    ADD CONSTRAINT "itinerary_stays_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_transports"
    ADD CONSTRAINT "itinerary_transports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."markup_conditions"
    ADD CONSTRAINT "markup_conditions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."markup_rules"
    ADD CONSTRAINT "markup_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."organization_invites"
    ADD CONSTRAINT "organization_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."organization_invites"
    ADD CONSTRAINT "organization_invites_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."other_service_rates"
    ADD CONSTRAINT "other_service_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."other_services"
    ADD CONSTRAINT "other_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_override_logs"
    ADD CONSTRAINT "price_override_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stay_rooms"
    ADD CONSTRAINT "stay_rooms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."suppliers"
    ADD CONSTRAINT "suppliers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transport_rates"
    ADD CONSTRAINT "transport_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transport_rates"
    ADD CONSTRAINT "transport_rates_transport_id_supplier_id_key" UNIQUE ("transport_id", "supplier_id");



ALTER TABLE ONLY "public"."transports"
    ADD CONSTRAINT "transports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "unique_location_name_per_org" UNIQUE ("organization_id", "name");



CREATE INDEX "idx_accommodation_rooms_org_active" ON "public"."accommodation_rooms" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_accommodations_org_active" ON "public"."accommodations" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_activities_org_active" ON "public"."activities" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_activity_rates_org_active" ON "public"."activity_rates" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_agents_org_active" ON "public"."agents" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_clients_org_active" ON "public"."clients" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_consortiums_org_active" ON "public"."consortiums" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_exchange_rates_org" ON "public"."exchange_rates" USING "btree" ("organization_id");



CREATE INDEX "idx_exchange_rates_pair" ON "public"."exchange_rates" USING "btree" ("from_currency", "to_currency");



CREATE INDEX "idx_exchange_rates_valid" ON "public"."exchange_rates" USING "btree" ("valid_from", "valid_until");



CREATE INDEX "idx_global_cities_aliases" ON "public"."global_cities" USING "gin" ("alternatenames" "public"."gin_trgm_ops");



CREATE INDEX "idx_global_cities_ascii" ON "public"."global_cities" USING "gin" ("asciiname" "public"."gin_trgm_ops");



CREATE INDEX "idx_guide_rates_guide" ON "public"."guide_rates" USING "btree" ("guide_id");



CREATE INDEX "idx_guide_rates_org" ON "public"."guide_rates" USING "btree" ("organization_id");



CREATE INDEX "idx_guide_rates_org_active" ON "public"."guide_rates" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_guides_org_active" ON "public"."guides" USING "btree" ("organization_id", "is_active");



CREATE UNIQUE INDEX "idx_itinerary_items_position" ON "public"."itinerary_items" USING "btree" ("itinerary_id", "day_number", "position");



CREATE INDEX "idx_locations_org_active" ON "public"."locations" USING "btree" ("organization_id", "is_active");



CREATE UNIQUE INDEX "idx_locations_org_name_unique" ON "public"."locations" USING "btree" ("organization_id", "lower"(TRIM(BOTH FROM "name")));



CREATE INDEX "idx_other_service_rates_org" ON "public"."other_service_rates" USING "btree" ("organization_id");



CREATE INDEX "idx_other_service_rates_service" ON "public"."other_service_rates" USING "btree" ("other_service_id");



CREATE INDEX "idx_other_services_org_active" ON "public"."other_services" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_suppliers_org_active" ON "public"."suppliers" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_transport_rates_org_active" ON "public"."transport_rates" USING "btree" ("organization_id", "is_active");



CREATE INDEX "idx_transports_org_active" ON "public"."transports" USING "btree" ("organization_id", "is_active");



CREATE UNIQUE INDEX "unique_org_accommodation_name" ON "public"."accommodations" USING "btree" ("organization_id", "lower"(TRIM(BOTH FROM "name")));



CREATE UNIQUE INDEX "unique_org_activity_name" ON "public"."activities" USING "btree" ("organization_id", "lower"(TRIM(BOTH FROM "name")));



CREATE UNIQUE INDEX "unique_org_agent_email" ON "public"."agents" USING "btree" ("organization_id", "email") WHERE (("email" IS NOT NULL) AND ("email" <> ''::"text"));



CREATE UNIQUE INDEX "unique_org_client_email" ON "public"."clients" USING "btree" ("organization_id", "email") WHERE (("email" IS NOT NULL) AND ("email" <> ''::"text"));



CREATE UNIQUE INDEX "unique_org_supplier_email" ON "public"."suppliers" USING "btree" ("organization_id", "contact_email") WHERE (("contact_email" IS NOT NULL) AND ("contact_email" <> ''::"text"));



CREATE UNIQUE INDEX "unique_org_transport_logistics" ON "public"."transports" USING "btree" ("organization_id", "service_type", "lower"(TRIM(BOTH FROM COALESCE("name", ''::"text"))));



CREATE OR REPLACE TRIGGER "tr_exchange_rates_updated_at" BEFORE UPDATE ON "public"."exchange_rates" FOR EACH ROW EXECUTE FUNCTION "public"."update_exchange_rate_timestamp"();



CREATE OR REPLACE TRIGGER "tr_guide_rates_updated_at" BEFORE UPDATE ON "public"."guide_rates" FOR EACH ROW EXECUTE FUNCTION "public"."update_guide_rate_timestamp"();



CREATE OR REPLACE TRIGGER "tr_itineraries_snapshot" BEFORE INSERT OR UPDATE OF "agent_id", "consortium_id" ON "public"."itineraries" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_itinerary"();



CREATE OR REPLACE TRIGGER "tr_itinerary_activities_snapshot" BEFORE INSERT OR UPDATE OF "activity_id", "selected_supplier_rate_id" ON "public"."itinerary_activities" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_activity"();



CREATE OR REPLACE TRIGGER "tr_itinerary_activity_components_snapshot" BEFORE INSERT OR UPDATE OF "activity_rate_id" ON "public"."itinerary_activity_components" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_activity_component"();



CREATE OR REPLACE TRIGGER "tr_itinerary_guide_segments_snapshot" BEFORE INSERT OR UPDATE OF "guide_rate_id" ON "public"."itinerary_guide_segments" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_guide_segment"();



CREATE OR REPLACE TRIGGER "tr_itinerary_guides_snapshot" BEFORE INSERT OR UPDATE OF "guide_id", "selected_rate_id" ON "public"."itinerary_guides" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_guide"();



CREATE OR REPLACE TRIGGER "tr_itinerary_other_services_snapshot" BEFORE INSERT OR UPDATE OF "service_id" ON "public"."itinerary_other_services" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_other_service"();



CREATE OR REPLACE TRIGGER "tr_itinerary_pax_snapshot" BEFORE INSERT OR UPDATE OF "client_id" ON "public"."itinerary_pax" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_itinerary_pax"();



CREATE OR REPLACE TRIGGER "tr_itinerary_stays_snapshot" BEFORE INSERT OR UPDATE OF "accommodation_id" ON "public"."itinerary_stays" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_stay"();



CREATE OR REPLACE TRIGGER "tr_itinerary_transports_snapshot" BEFORE INSERT OR UPDATE OF "transport_id", "selected_supplier_rate_id" ON "public"."itinerary_transports" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_transport"();



CREATE OR REPLACE TRIGGER "tr_other_service_rates_updated_at" BEFORE UPDATE ON "public"."other_service_rates" FOR EACH ROW EXECUTE FUNCTION "public"."update_other_service_rate_timestamp"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_accommodation_room_rates" BEFORE DELETE ON "public"."accommodation_room_rates" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_accommodation_rooms" BEFORE DELETE ON "public"."accommodation_rooms" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_accommodation_seasons" BEFORE DELETE ON "public"."accommodation_seasons" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_accommodations" BEFORE DELETE ON "public"."accommodations" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_activities" BEFORE DELETE ON "public"."activities" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_activity_rates" BEFORE DELETE ON "public"."activity_rates" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_guide_rates" BEFORE DELETE ON "public"."guide_rates" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_guides" BEFORE DELETE ON "public"."guides" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_locations" BEFORE DELETE ON "public"."locations" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_other_service_rates" BEFORE DELETE ON "public"."other_service_rates" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_other_services" BEFORE DELETE ON "public"."other_services" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_suppliers" BEFORE DELETE ON "public"."suppliers" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_transport_rates" BEFORE DELETE ON "public"."transport_rates" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_soft_delete_transports" BEFORE DELETE ON "public"."transports" FOR EACH ROW EXECUTE FUNCTION "public"."trg_soft_delete"();



CREATE OR REPLACE TRIGGER "tr_stay_rooms_snapshot" BEFORE INSERT OR UPDATE OF "room_id" ON "public"."stay_rooms" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fill_snapshot_stay_room"();



CREATE OR REPLACE TRIGGER "tr_sync_accom_types" AFTER INSERT OR DELETE OR UPDATE ON "public"."accommodations" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sync_supplier_service_types"();



CREATE OR REPLACE TRIGGER "tr_sync_guide_types" AFTER INSERT OR DELETE OR UPDATE ON "public"."guides" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sync_supplier_service_types"();



CREATE OR REPLACE TRIGGER "tr_sync_other_types" AFTER INSERT OR DELETE OR UPDATE ON "public"."other_services" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sync_supplier_service_types"();



CREATE OR REPLACE TRIGGER "tr_sync_supplier_activity_rates" AFTER INSERT OR DELETE OR UPDATE ON "public"."activity_rates" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sync_supplier_service_types"();



CREATE OR REPLACE TRIGGER "tr_sync_supplier_transport_rates" AFTER INSERT OR DELETE OR UPDATE ON "public"."transport_rates" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sync_supplier_service_types"();



CREATE OR REPLACE TRIGGER "trg_validate_catalog_price_other_services" BEFORE INSERT OR UPDATE OF "unit_price", "total_price" ON "public"."itinerary_other_services" FOR EACH ROW EXECUTE FUNCTION "public"."validate_catalog_price"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_activities" BEFORE UPDATE OF "manual_cost_override", "rate_justification" ON "public"."itinerary_activities" FOR EACH ROW EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_guides" BEFORE UPDATE OF "manual_cost_override", "rate_justification" ON "public"."itinerary_guides" FOR EACH ROW EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_insert_activities" BEFORE INSERT ON "public"."itinerary_activities" FOR EACH ROW WHEN (("new"."manual_cost_override" IS NOT NULL)) EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_insert_guides" BEFORE INSERT ON "public"."itinerary_guides" FOR EACH ROW WHEN (("new"."manual_cost_override" IS NOT NULL)) EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_insert_other_services" BEFORE INSERT ON "public"."itinerary_other_services" FOR EACH ROW WHEN (("new"."manual_cost_override" IS NOT NULL)) EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_insert_stay_rooms" BEFORE INSERT ON "public"."stay_rooms" FOR EACH ROW WHEN (("new"."manual_cost_override" IS NOT NULL)) EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_insert_transports" BEFORE INSERT ON "public"."itinerary_transports" FOR EACH ROW WHEN (("new"."manual_cost_override" IS NOT NULL)) EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_other_services" BEFORE UPDATE OF "manual_cost_override", "rate_justification" ON "public"."itinerary_other_services" FOR EACH ROW EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_stay_rooms" BEFORE UPDATE OF "manual_cost_override", "rate_justification" ON "public"."stay_rooms" FOR EACH ROW EXECUTE FUNCTION "public"."validate_price_override"();



CREATE OR REPLACE TRIGGER "trg_validate_price_override_transports" BEFORE UPDATE OF "manual_cost_override", "rate_justification" ON "public"."itinerary_transports" FOR EACH ROW EXECUTE FUNCTION "public"."validate_price_override"();



ALTER TABLE ONLY "public"."accommodation_room_rates"
    ADD CONSTRAINT "accommodation_room_rates_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."accommodation_room_rates"
    ADD CONSTRAINT "accommodation_room_rates_room_id_fkey" FOREIGN KEY ("room_id") REFERENCES "public"."accommodation_rooms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."accommodation_room_rates"
    ADD CONSTRAINT "accommodation_room_rates_season_id_fkey" FOREIGN KEY ("season_id") REFERENCES "public"."accommodation_seasons"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."accommodation_rooms"
    ADD CONSTRAINT "accommodation_rooms_accommodation_id_fkey" FOREIGN KEY ("accommodation_id") REFERENCES "public"."accommodations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."accommodation_rooms"
    ADD CONSTRAINT "accommodation_rooms_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."accommodation_seasons"
    ADD CONSTRAINT "accommodation_seasons_accommodation_id_fkey" FOREIGN KEY ("accommodation_id") REFERENCES "public"."accommodations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."accommodation_seasons"
    ADD CONSTRAINT "accommodation_seasons_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."accommodations"
    ADD CONSTRAINT "accommodations_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."accommodations"
    ADD CONSTRAINT "accommodations_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."accommodations"
    ADD CONSTRAINT "accommodations_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."activity_rates"
    ADD CONSTRAINT "activity_rates_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity_rates"
    ADD CONSTRAINT "activity_rates_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity_rates"
    ADD CONSTRAINT "activity_rates_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agents"
    ADD CONSTRAINT "agents_associated_consortium_id_fkey" FOREIGN KEY ("associated_consortium_id") REFERENCES "public"."consortiums"("id");



ALTER TABLE ONLY "public"."agents"
    ADD CONSTRAINT "agents_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_referred_by_agent_id_fkey" FOREIGN KEY ("referred_by_agent_id") REFERENCES "public"."agents"("id");



ALTER TABLE ONLY "public"."consortiums"
    ADD CONSTRAINT "consortiums_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."guide_rates"
    ADD CONSTRAINT "guide_rates_guide_id_fkey" FOREIGN KEY ("guide_id") REFERENCES "public"."guides"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."guide_rates"
    ADD CONSTRAINT "guide_rates_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."guides"
    ADD CONSTRAINT "guides_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."guides"
    ADD CONSTRAINT "guides_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."guides"
    ADD CONSTRAINT "guides_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."agents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_assigned_to_profile_fkey" FOREIGN KEY ("assigned_to_profile") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_consortium_id_fkey" FOREIGN KEY ("consortium_id") REFERENCES "public"."consortiums"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_exchange_rate_id_fkey" FOREIGN KEY ("exchange_rate_id") REFERENCES "public"."exchange_rates"("id");



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_manual_markup_rule_id_fkey" FOREIGN KEY ("manual_markup_rule_id") REFERENCES "public"."markup_rules"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_manual_overhead_rule_id_fkey" FOREIGN KEY ("manual_overhead_rule_id") REFERENCES "public"."markup_rules"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_activities"
    ADD CONSTRAINT "itinerary_activities_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itinerary_activities"
    ADD CONSTRAINT "itinerary_activities_calculated_by_fkey" FOREIGN KEY ("calculated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itinerary_activities"
    ADD CONSTRAINT "itinerary_activities_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_activities"
    ADD CONSTRAINT "itinerary_activities_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_activities"
    ADD CONSTRAINT "itinerary_activities_selected_supplier_rate_id_fkey" FOREIGN KEY ("selected_supplier_rate_id") REFERENCES "public"."activity_rates"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itinerary_activity_components"
    ADD CONSTRAINT "itinerary_activity_components_activity_rate_id_fkey" FOREIGN KEY ("activity_rate_id") REFERENCES "public"."activity_rates"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itinerary_activity_components"
    ADD CONSTRAINT "itinerary_activity_components_itinerary_activity_id_fkey" FOREIGN KEY ("itinerary_activity_id") REFERENCES "public"."itinerary_activities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_activity_components"
    ADD CONSTRAINT "itinerary_activity_components_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_guide_segments"
    ADD CONSTRAINT "itinerary_guide_segments_calculated_by_fkey" FOREIGN KEY ("calculated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."itinerary_guide_segments"
    ADD CONSTRAINT "itinerary_guide_segments_guide_rate_id_fkey" FOREIGN KEY ("guide_rate_id") REFERENCES "public"."guide_rates"("id");



ALTER TABLE ONLY "public"."itinerary_guide_segments"
    ADD CONSTRAINT "itinerary_guide_segments_itinerary_guide_id_fkey" FOREIGN KEY ("itinerary_guide_id") REFERENCES "public"."itinerary_guides"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_guide_segments"
    ADD CONSTRAINT "itinerary_guide_segments_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_guides"
    ADD CONSTRAINT "itinerary_guides_calculated_by_fkey" FOREIGN KEY ("calculated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."itinerary_guides"
    ADD CONSTRAINT "itinerary_guides_guide_id_fkey" FOREIGN KEY ("guide_id") REFERENCES "public"."guides"("id");



ALTER TABLE ONLY "public"."itinerary_guides"
    ADD CONSTRAINT "itinerary_guides_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_guides"
    ADD CONSTRAINT "itinerary_guides_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_guides"
    ADD CONSTRAINT "itinerary_guides_selected_rate_id_fkey" FOREIGN KEY ("selected_rate_id") REFERENCES "public"."guide_rates"("id");



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activities"("id");



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_calculated_by_fkey" FOREIGN KEY ("calculated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_itinerary_activity_id_fkey" FOREIGN KEY ("itinerary_activity_id") REFERENCES "public"."itinerary_activities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_itinerary_guide_id_fkey" FOREIGN KEY ("itinerary_guide_id") REFERENCES "public"."itinerary_guides"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_itinerary_transport_id_fkey" FOREIGN KEY ("itinerary_transport_id") REFERENCES "public"."itinerary_transports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_items"
    ADD CONSTRAINT "itinerary_items_stay_id_fkey" FOREIGN KEY ("stay_id") REFERENCES "public"."itinerary_stays"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_notes"
    ADD CONSTRAINT "itinerary_notes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."itinerary_notes"
    ADD CONSTRAINT "itinerary_notes_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_notes"
    ADD CONSTRAINT "itinerary_notes_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_other_services"
    ADD CONSTRAINT "itinerary_other_services_calculated_by_fkey" FOREIGN KEY ("calculated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."itinerary_other_services"
    ADD CONSTRAINT "itinerary_other_services_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_other_services"
    ADD CONSTRAINT "itinerary_other_services_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_other_services"
    ADD CONSTRAINT "itinerary_other_services_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."other_services"("id");



ALTER TABLE ONLY "public"."itinerary_pax"
    ADD CONSTRAINT "itinerary_pax_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_pax"
    ADD CONSTRAINT "itinerary_pax_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_pax"
    ADD CONSTRAINT "itinerary_pax_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_requirements"
    ADD CONSTRAINT "itinerary_requirements_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_requirements"
    ADD CONSTRAINT "itinerary_requirements_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_stays"
    ADD CONSTRAINT "itinerary_stays_accommodation_id_fkey" FOREIGN KEY ("accommodation_id") REFERENCES "public"."accommodations"("id");



ALTER TABLE ONLY "public"."itinerary_stays"
    ADD CONSTRAINT "itinerary_stays_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_stays"
    ADD CONSTRAINT "itinerary_stays_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_transports"
    ADD CONSTRAINT "itinerary_transports_calculated_by_fkey" FOREIGN KEY ("calculated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."itinerary_transports"
    ADD CONSTRAINT "itinerary_transports_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_transports"
    ADD CONSTRAINT "itinerary_transports_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."itinerary_transports"
    ADD CONSTRAINT "itinerary_transports_selected_supplier_rate_id_fkey" FOREIGN KEY ("selected_supplier_rate_id") REFERENCES "public"."transport_rates"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."itinerary_transports"
    ADD CONSTRAINT "itinerary_transports_transport_id_fkey" FOREIGN KEY ("transport_id") REFERENCES "public"."transports"("id");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."markup_conditions"
    ADD CONSTRAINT "markup_conditions_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."markup_conditions"
    ADD CONSTRAINT "markup_conditions_rule_id_fkey" FOREIGN KEY ("rule_id") REFERENCES "public"."markup_rules"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."markup_rules"
    ADD CONSTRAINT "markup_rules_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."markup_rules"
    ADD CONSTRAINT "markup_rules_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."organization_invites"
    ADD CONSTRAINT "organization_invites_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."other_service_rates"
    ADD CONSTRAINT "other_service_rates_other_service_id_fkey" FOREIGN KEY ("other_service_id") REFERENCES "public"."other_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."other_service_rates"
    ADD CONSTRAINT "other_service_rates_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id");



ALTER TABLE ONLY "public"."other_services"
    ADD CONSTRAINT "other_services_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."other_services"
    ADD CONSTRAINT "other_services_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."other_services"
    ADD CONSTRAINT "other_services_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_override_logs"
    ADD CONSTRAINT "price_override_logs_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id");



ALTER TABLE ONLY "public"."price_override_logs"
    ADD CONSTRAINT "price_override_logs_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."price_override_logs"
    ADD CONSTRAINT "price_override_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."stay_rooms"
    ADD CONSTRAINT "stay_rooms_calculated_by_fkey" FOREIGN KEY ("calculated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."stay_rooms"
    ADD CONSTRAINT "stay_rooms_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."stay_rooms"
    ADD CONSTRAINT "stay_rooms_room_id_fkey" FOREIGN KEY ("room_id") REFERENCES "public"."accommodation_rooms"("id");



ALTER TABLE ONLY "public"."stay_rooms"
    ADD CONSTRAINT "stay_rooms_selected_supplier_rate_id_fkey" FOREIGN KEY ("selected_supplier_rate_id") REFERENCES "public"."accommodation_room_rates"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."stay_rooms"
    ADD CONSTRAINT "stay_rooms_stay_id_fkey" FOREIGN KEY ("stay_id") REFERENCES "public"."itinerary_stays"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."suppliers"
    ADD CONSTRAINT "suppliers_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."transport_rates"
    ADD CONSTRAINT "transport_rates_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."transport_rates"
    ADD CONSTRAINT "transport_rates_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transport_rates"
    ADD CONSTRAINT "transport_rates_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transport_rates"
    ADD CONSTRAINT "transport_rates_transport_id_fkey" FOREIGN KEY ("transport_id") REFERENCES "public"."transports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transports"
    ADD CONSTRAINT "transports_destination_id_fkey" FOREIGN KEY ("destination_id") REFERENCES "public"."locations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."transports"
    ADD CONSTRAINT "transports_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."transports"
    ADD CONSTRAINT "transports_origin_id_fkey" FOREIGN KEY ("origin_id") REFERENCES "public"."locations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."transports"
    ADD CONSTRAINT "transports_return_route_id_fkey" FOREIGN KEY ("return_route_id") REFERENCES "public"."transports"("id");



CREATE POLICY "Aislamiento de la Organizacion" ON "public"."organizations" TO "authenticated" USING (("id" = "public"."get_auth_org_id"()));



CREATE POLICY "Ciudades globales lectura publica" ON "public"."global_cities" FOR SELECT USING (true);



CREATE POLICY "Edicion propia" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"()));



CREATE POLICY "Enable delete for org members" ON "public"."markup_rules" FOR DELETE USING (("organization_id" = (("auth"."jwt"() ->> 'organization_id'::"text"))::"uuid"));



CREATE POLICY "Enable delete for org members via rules" ON "public"."markup_conditions" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."markup_rules"
  WHERE (("markup_rules"."id" = "markup_conditions"."rule_id") AND ("markup_rules"."organization_id" = (("auth"."jwt"() ->> 'organization_id'::"text"))::"uuid")))));



CREATE POLICY "Enable insert for org members" ON "public"."markup_rules" FOR INSERT WITH CHECK (("organization_id" = (("auth"."jwt"() ->> 'organization_id'::"text"))::"uuid"));



CREATE POLICY "Enable insert for org members via rules" ON "public"."markup_conditions" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."markup_rules"
  WHERE (("markup_rules"."id" = "markup_conditions"."rule_id") AND ("markup_rules"."organization_id" = (("auth"."jwt"() ->> 'organization_id'::"text"))::"uuid")))));



CREATE POLICY "Enable read for org members" ON "public"."markup_rules" FOR SELECT USING (("organization_id" = (("auth"."jwt"() ->> 'organization_id'::"text"))::"uuid"));



CREATE POLICY "Enable read for org members via rules" ON "public"."markup_conditions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."markup_rules"
  WHERE (("markup_rules"."id" = "markup_conditions"."rule_id") AND ("markup_rules"."organization_id" = (("auth"."jwt"() ->> 'organization_id'::"text"))::"uuid")))));



CREATE POLICY "Enable update for org members" ON "public"."markup_rules" FOR UPDATE USING (("organization_id" = (("auth"."jwt"() ->> 'organization_id'::"text"))::"uuid"));



CREATE POLICY "Enable update for org members via rules" ON "public"."markup_conditions" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."markup_rules"
  WHERE (("markup_rules"."id" = "markup_conditions"."rule_id") AND ("markup_rules"."organization_id" = (("auth"."jwt"() ->> 'organization_id'::"text"))::"uuid")))));



CREATE POLICY "Lectura universal sin recursion" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "RLS_AccommodationRoomRates" ON "public"."accommodation_room_rates" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_AccommodationRooms" ON "public"."accommodation_rooms" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_AccommodationSeasons" ON "public"."accommodation_seasons" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_Accommodations" ON "public"."accommodations" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_Activities" ON "public"."activities" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_ActivityRates" ON "public"."activity_rates" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_ExchangeRates" ON "public"."exchange_rates" USING (("organization_id" = "public"."get_org_id"()));



CREATE POLICY "RLS_GuideRates" ON "public"."guide_rates" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_Guides" ON "public"."guides" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_Locations" ON "public"."locations" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_OtherServiceRates" ON "public"."other_service_rates" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_OtherServices" ON "public"."other_services" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_Suppliers" ON "public"."suppliers" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_TransportRates" ON "public"."transport_rates" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "RLS_Transports" ON "public"."transports" USING ((("organization_id" = "public"."get_org_id"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "Tenant Isolation" ON "public"."accommodation_room_rates" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."accommodation_rooms" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."accommodation_seasons" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."accommodations" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."activities" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."activity_rates" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."agents" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."clients" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."consortiums" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."guide_rates" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."guides" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itineraries" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_activities" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_activity_components" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_guide_segments" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_guides" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_items" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_notes" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_other_services" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_pax" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_requirements" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_stays" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."itinerary_transports" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."locations" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."markup_conditions" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."markup_rules" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."organization_invites" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."other_services" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."price_override_logs" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."stay_rooms" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."suppliers" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."transport_rates" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation" ON "public"."transports" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation exchange_rates" ON "public"."exchange_rates" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation guide_rates" ON "public"."guide_rates" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



CREATE POLICY "Tenant Isolation other_service_rates" ON "public"."other_service_rates" TO "authenticated" USING (("organization_id" = "public"."get_auth_org_id"())) WITH CHECK (("organization_id" = "public"."get_auth_org_id"()));



ALTER TABLE "public"."accommodation_room_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."accommodation_rooms" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."accommodation_seasons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."accommodations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."activities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."activity_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."consortiums" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."exchange_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."global_cities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."guide_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."guides" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itineraries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_activities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_activity_components" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_guide_segments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_guides" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_other_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_pax" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_requirements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_stays" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itinerary_transports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."locations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."markup_conditions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."markup_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."organization_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."organizations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."other_service_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."other_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."price_override_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stay_rooms" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."suppliers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transport_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transports" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_unassigned_services"("target_supplier_id" "uuid", "org_id" "uuid", "accommodation_ids" "uuid"[], "transport_ids" "uuid"[], "activity_ids" "uuid"[], "guide_ids" "uuid"[], "other_service_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."assign_unassigned_services"("target_supplier_id" "uuid", "org_id" "uuid", "accommodation_ids" "uuid"[], "transport_ids" "uuid"[], "activity_ids" "uuid"[], "guide_ids" "uuid"[], "other_service_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_unassigned_services"("target_supplier_id" "uuid", "org_id" "uuid", "accommodation_ids" "uuid"[], "transport_ids" "uuid"[], "activity_ids" "uuid"[], "guide_ids" "uuid"[], "other_service_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."batch_assign_services_v2"("p_org_id" "uuid", "p_supplier_id" "uuid", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."batch_assign_services_v2"("p_org_id" "uuid", "p_supplier_id" "uuid", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."batch_assign_services_v2"("p_org_id" "uuid", "p_supplier_id" "uuid", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid", "p_activity_fk" "uuid", "p_rate_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid", "p_activity_fk" "uuid", "p_rate_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_activity_service_snapshot"("p_activity_id" "uuid", "p_activity_fk" "uuid", "p_rate_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid", "p_guide_fk" "uuid", "p_rate_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid", "p_guide_fk" "uuid", "p_rate_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_guide_service_snapshot"("p_guide_id" "uuid", "p_guide_fk" "uuid", "p_rate_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid", "p_accommodation_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid", "p_accommodation_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_stay_service_snapshot"("p_stay_id" "uuid", "p_accommodation_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid", "p_transport_fk" "uuid", "p_rate_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid", "p_transport_fk" "uuid", "p_rate_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_transport_service_snapshot"("p_transport_id" "uuid", "p_transport_fk" "uuid", "p_rate_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."execute_merge_suppliers"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "text"[], "merged_internal_docs" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."execute_merge_suppliers"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "text"[], "merged_internal_docs" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."execute_merge_suppliers"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "text"[], "merged_internal_docs" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_sync_supplier_service_types"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_sync_supplier_service_types"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_sync_supplier_service_types"() TO "service_role";



GRANT ALL ON FUNCTION "public"."freeze_itinerary_quote"("p_itinerary_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."freeze_itinerary_quote"("p_itinerary_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."freeze_itinerary_quote"("p_itinerary_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_auth_org_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_auth_org_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_auth_org_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_locations_with_stats"("org_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_locations_with_stats"("org_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_locations_with_stats"("org_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_or_create_location"("p_name" "text", "p_country_code" "text", "p_org_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_or_create_location"("p_name" "text", "p_country_code" "text", "p_org_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_or_create_location"("p_name" "text", "p_country_code" "text", "p_org_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_org_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_org_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_org_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_orphan_locations"("org_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_orphan_locations"("org_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_orphan_locations"("org_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pending_services"("org_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_pending_services"("org_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_services"("org_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."merge_suppliers"("p_payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."merge_suppliers"("p_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_suppliers"("p_payload" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."merge_suppliers_v2"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "jsonb", "merged_internal_docs" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."merge_suppliers_v2"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "jsonb", "merged_internal_docs" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_suppliers_v2"("keeper_id" "uuid", "discarded_id" "uuid", "merged_name" "text", "merged_email" "text", "merged_phone" "text", "merged_category" "text", "merged_tags" "jsonb", "merged_internal_docs" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."org_id_jwt_hook"() TO "anon";
GRANT ALL ON FUNCTION "public"."org_id_jwt_hook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."org_id_jwt_hook"() TO "service_role";



GRANT ALL ON FUNCTION "public"."resurrect_record"("p_table" "text", "p_record_id" "uuid", "p_organization_id" "uuid", "p_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."resurrect_record"("p_table" "text", "p_record_id" "uuid", "p_organization_id" "uuid", "p_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resurrect_record"("p_table" "text", "p_record_id" "uuid", "p_organization_id" "uuid", "p_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_bulk_hard_delete"("p_table" "text", "p_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_bulk_hard_delete"("p_table" "text", "p_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_bulk_hard_delete"("p_table" "text", "p_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_bulk_insert"("p_table" "text", "p_payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_bulk_insert"("p_table" "text", "p_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_bulk_insert"("p_table" "text", "p_payload" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_bulk_soft_delete"("p_table" "text", "p_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_bulk_soft_delete"("p_table" "text", "p_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_bulk_soft_delete"("p_table" "text", "p_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_rebuild_snapshot"("p_table" "text", "p_record_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_rebuild_snapshot"("p_table" "text", "p_record_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_rebuild_snapshot"("p_table" "text", "p_record_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_stay_rooms"("p_stay_id" "uuid", "p_rooms" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."sync_stay_rooms"("p_stay_id" "uuid", "p_rooms" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_stay_rooms"("p_stay_id" "uuid", "p_rooms" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_activity"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_activity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_activity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_activity_component"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_activity_component"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_activity_component"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_guide"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_guide"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_guide"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_guide_segment"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_guide_segment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_guide_segment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_itinerary"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_itinerary"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_itinerary"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_itinerary_pax"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_itinerary_pax"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_itinerary_pax"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_other_service"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_other_service"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_other_service"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_stay"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_stay"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_stay"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_stay_room"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_stay_room"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_stay_room"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_transport"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_transport"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fill_snapshot_transport"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_soft_delete"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_soft_delete"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_soft_delete"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_exchange_rate_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_exchange_rate_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_exchange_rate_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_guide_rate_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_guide_rate_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_guide_rate_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_itinerary_items_positions"("p_updates" "jsonb", "p_itinerary_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."update_itinerary_items_positions"("p_updates" "jsonb", "p_itinerary_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_itinerary_items_positions"("p_updates" "jsonb", "p_itinerary_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_other_service_rate_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_other_service_rate_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_other_service_rate_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_team_member_role"("p_user_id" "uuid", "p_new_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_team_member_role"("p_user_id" "uuid", "p_new_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_team_member_role"("p_user_id" "uuid", "p_new_role" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_catalog_price"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_catalog_price"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_catalog_price"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_price_override"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_price_override"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_price_override"() TO "service_role";



GRANT ALL ON TABLE "public"."accommodation_room_rates" TO "anon";
GRANT ALL ON TABLE "public"."accommodation_room_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."accommodation_room_rates" TO "service_role";



GRANT ALL ON TABLE "public"."accommodation_rooms" TO "anon";
GRANT ALL ON TABLE "public"."accommodation_rooms" TO "authenticated";
GRANT ALL ON TABLE "public"."accommodation_rooms" TO "service_role";



GRANT ALL ON TABLE "public"."accommodation_seasons" TO "anon";
GRANT ALL ON TABLE "public"."accommodation_seasons" TO "authenticated";
GRANT ALL ON TABLE "public"."accommodation_seasons" TO "service_role";



GRANT ALL ON TABLE "public"."accommodations" TO "anon";
GRANT ALL ON TABLE "public"."accommodations" TO "authenticated";
GRANT ALL ON TABLE "public"."accommodations" TO "service_role";



GRANT ALL ON TABLE "public"."activities" TO "anon";
GRANT ALL ON TABLE "public"."activities" TO "authenticated";
GRANT ALL ON TABLE "public"."activities" TO "service_role";



GRANT ALL ON TABLE "public"."activity_rates" TO "anon";
GRANT ALL ON TABLE "public"."activity_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."activity_rates" TO "service_role";



GRANT ALL ON TABLE "public"."agents" TO "anon";
GRANT ALL ON TABLE "public"."agents" TO "authenticated";
GRANT ALL ON TABLE "public"."agents" TO "service_role";



GRANT ALL ON TABLE "public"."clients" TO "anon";
GRANT ALL ON TABLE "public"."clients" TO "authenticated";
GRANT ALL ON TABLE "public"."clients" TO "service_role";



GRANT ALL ON TABLE "public"."consortiums" TO "anon";
GRANT ALL ON TABLE "public"."consortiums" TO "authenticated";
GRANT ALL ON TABLE "public"."consortiums" TO "service_role";



GRANT ALL ON TABLE "public"."exchange_rates" TO "anon";
GRANT ALL ON TABLE "public"."exchange_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."exchange_rates" TO "service_role";



GRANT ALL ON TABLE "public"."global_cities" TO "anon";
GRANT ALL ON TABLE "public"."global_cities" TO "authenticated";
GRANT ALL ON TABLE "public"."global_cities" TO "service_role";



GRANT ALL ON SEQUENCE "public"."global_cities_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."global_cities_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."global_cities_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."guide_rates" TO "anon";
GRANT ALL ON TABLE "public"."guide_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."guide_rates" TO "service_role";



GRANT ALL ON TABLE "public"."guides" TO "anon";
GRANT ALL ON TABLE "public"."guides" TO "authenticated";
GRANT ALL ON TABLE "public"."guides" TO "service_role";



GRANT ALL ON SEQUENCE "public"."itinerary_ref_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."itinerary_ref_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."itinerary_ref_seq" TO "service_role";



GRANT ALL ON TABLE "public"."itineraries" TO "anon";
GRANT ALL ON TABLE "public"."itineraries" TO "authenticated";
GRANT ALL ON TABLE "public"."itineraries" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_activities" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_activities" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_activities" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_activity_components" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_activity_components" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_activity_components" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_guide_segments" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_guide_segments" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_guide_segments" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_guides" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_guides" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_guides" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_items" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_items" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_items" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_notes" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_notes" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_other_services" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_other_services" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_other_services" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_pax" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_pax" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_pax" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_requirements" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_requirements" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_requirements" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_stays" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_stays" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_stays" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_transports" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_transports" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_transports" TO "service_role";



GRANT ALL ON TABLE "public"."locations" TO "anon";
GRANT ALL ON TABLE "public"."locations" TO "authenticated";
GRANT ALL ON TABLE "public"."locations" TO "service_role";



GRANT ALL ON TABLE "public"."markup_conditions" TO "anon";
GRANT ALL ON TABLE "public"."markup_conditions" TO "authenticated";
GRANT ALL ON TABLE "public"."markup_conditions" TO "service_role";



GRANT ALL ON TABLE "public"."markup_rules" TO "anon";
GRANT ALL ON TABLE "public"."markup_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."markup_rules" TO "service_role";



GRANT ALL ON TABLE "public"."organization_invites" TO "anon";
GRANT ALL ON TABLE "public"."organization_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."organization_invites" TO "service_role";



GRANT ALL ON TABLE "public"."organizations" TO "anon";
GRANT ALL ON TABLE "public"."organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."organizations" TO "service_role";



GRANT ALL ON TABLE "public"."other_service_rates" TO "anon";
GRANT ALL ON TABLE "public"."other_service_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."other_service_rates" TO "service_role";



GRANT ALL ON TABLE "public"."other_services" TO "anon";
GRANT ALL ON TABLE "public"."other_services" TO "authenticated";
GRANT ALL ON TABLE "public"."other_services" TO "service_role";



GRANT ALL ON TABLE "public"."price_override_logs" TO "anon";
GRANT ALL ON TABLE "public"."price_override_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."price_override_logs" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."stay_rooms" TO "anon";
GRANT ALL ON TABLE "public"."stay_rooms" TO "authenticated";
GRANT ALL ON TABLE "public"."stay_rooms" TO "service_role";



GRANT ALL ON TABLE "public"."suppliers" TO "anon";
GRANT ALL ON TABLE "public"."suppliers" TO "authenticated";
GRANT ALL ON TABLE "public"."suppliers" TO "service_role";



GRANT ALL ON TABLE "public"."transport_rates" TO "anon";
GRANT ALL ON TABLE "public"."transport_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."transport_rates" TO "service_role";



GRANT ALL ON TABLE "public"."transports" TO "anon";
GRANT ALL ON TABLE "public"."transports" TO "authenticated";
GRANT ALL ON TABLE "public"."transports" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







