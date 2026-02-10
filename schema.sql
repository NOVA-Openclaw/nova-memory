--
-- PostgreSQL database dump
--

\restrict DL5BLliozNxgkw9q3q3NmXKHaV8PZDdFDDq54ClC3zolTBTJDCsFSN7gzFJ5cdR

-- Dumped from database version 16.11 (Ubuntu 16.11-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.11 (Ubuntu 16.11-0ubuntu0.24.04.1)

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

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: agent_chat_status; Type: TYPE; Schema: public; Owner: nova
--

CREATE TYPE public.agent_chat_status AS ENUM (
    'received',
    'routed',
    'responded',
    'failed'
);


ALTER TYPE public.agent_chat_status OWNER TO nova;

--
-- Name: agent_set_collaborative(integer, boolean, jsonb, text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.agent_set_collaborative(p_agent_id integer, p_collaborative boolean, p_collaborate_config jsonb DEFAULT NULL::jsonb, p_modified_by text DEFAULT 'system'::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old_collaborative BOOLEAN;
    v_old_config JSONB;
BEGIN
    -- Get old values
    SELECT collaborative, collaborate_config 
    INTO v_old_collaborative, v_old_config
    FROM agents
    WHERE id = p_agent_id;
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Agent not found';
        RETURN;
    END IF;
    
    -- Update collaborative settings
    UPDATE agents
    SET collaborative = p_collaborative,
        collaborate_config = COALESCE(p_collaborate_config, collaborate_config),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_agent_id;
    
    -- Log collaborative change
    PERFORM log_agent_modification(
        p_agent_id, p_modified_by, 'collaborative',
        v_old_collaborative::TEXT, p_collaborative::TEXT
    );
    
    -- Log config change if provided
    IF p_collaborate_config IS NOT NULL THEN
        PERFORM log_agent_modification(
            p_agent_id, p_modified_by, 'collaborate_config',
            v_old_config::TEXT, p_collaborate_config::TEXT
        );
    END IF;
    
    RETURN QUERY SELECT TRUE, 'Collaborative settings updated successfully';
END;
$$;


ALTER FUNCTION public.agent_set_collaborative(p_agent_id integer, p_collaborative boolean, p_collaborate_config jsonb, p_modified_by text) OWNER TO nova;

--
-- Name: agent_set_model(integer, text, text, text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.agent_set_model(p_agent_id integer, p_new_model text, p_new_fallback text DEFAULT NULL::text, p_modified_by text DEFAULT 'system'::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old_model TEXT;
    v_old_fallback TEXT;
BEGIN
    -- Get old values
    SELECT model, fallback_model INTO v_old_model, v_old_fallback
    FROM agents
    WHERE id = p_agent_id;
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Agent not found';
        RETURN;
    END IF;
    
    -- Update model
    UPDATE agents
    SET model = p_new_model,
        fallback_model = COALESCE(p_new_fallback, fallback_model),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_agent_id;
    
    -- Log model change
    PERFORM log_agent_modification(
        p_agent_id, p_modified_by, 'model', 
        v_old_model, p_new_model
    );
    
    -- Log fallback change if provided
    IF p_new_fallback IS NOT NULL THEN
        PERFORM log_agent_modification(
            p_agent_id, p_modified_by, 'fallback_model',
            v_old_fallback, p_new_fallback
        );
    END IF;
    
    RETURN QUERY SELECT TRUE, 'Model configuration updated successfully';
END;
$$;


ALTER FUNCTION public.agent_set_model(p_agent_id integer, p_new_model text, p_new_fallback text, p_modified_by text) OWNER TO nova;

--
-- Name: agent_set_status(integer, text, text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.agent_set_status(p_agent_id integer, p_new_status text, p_modified_by text DEFAULT 'system'::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old_status TEXT;
    v_valid_statuses TEXT[] := ARRAY['active', 'inactive', 'suspended', 'archived'];
BEGIN
    -- Validate status value
    IF NOT (p_new_status = ANY(v_valid_statuses)) THEN
        RETURN QUERY SELECT FALSE, 
            'Invalid status. Must be one of: active, inactive, suspended, archived';
        RETURN;
    END IF;
    
    -- Get old status
    SELECT status INTO v_old_status
    FROM agents
    WHERE id = p_agent_id;
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Agent not found';
        RETURN;
    END IF;
    
    -- Update status
    UPDATE agents
    SET status = p_new_status,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_agent_id;
    
    -- Log modification
    PERFORM log_agent_modification(
        p_agent_id, p_modified_by, 'status', v_old_status, p_new_status
    );
    
    RETURN QUERY SELECT TRUE, 'Status updated successfully';
END;
$$;


ALTER FUNCTION public.agent_set_status(p_agent_id integer, p_new_status text, p_modified_by text) OWNER TO nova;

--
-- Name: agent_update(integer, text, text, text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.agent_update(p_agent_id integer, p_field_name text, p_new_value text, p_modified_by text DEFAULT 'system'::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_old_value TEXT;
    v_protected_fields TEXT[] := ARRAY['id', 'created_at'];
    v_sql TEXT;
BEGIN
    -- Check if field is protected
    IF p_field_name = ANY(v_protected_fields) THEN
        RETURN QUERY SELECT FALSE, 
            'Cannot modify protected field: ' || p_field_name;
        RETURN;
    END IF;
    
    -- Verify agent exists and get old value
    v_sql := format('SELECT %I::TEXT FROM agents WHERE id = $1', p_field_name);
    BEGIN
        EXECUTE v_sql INTO v_old_value USING p_agent_id;
    EXCEPTION
        WHEN undefined_column THEN
            RETURN QUERY SELECT FALSE, 'Invalid field name: ' || p_field_name;
            RETURN;
        WHEN OTHERS THEN
            RETURN QUERY SELECT FALSE, 'Error reading field: ' || SQLERRM;
            RETURN;
    END;
    
    IF v_old_value IS NULL AND NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Agent not found';
        RETURN;
    END IF;
    
    -- Update the field
    v_sql := format(
        'UPDATE agents SET %I = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2',
        p_field_name
    );
    BEGIN
        EXECUTE v_sql USING p_new_value, p_agent_id;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT FALSE, 'Error updating field: ' || SQLERRM;
            RETURN;
    END;
    
    -- Log modification
    PERFORM log_agent_modification(
        p_agent_id, p_modified_by, p_field_name, v_old_value, p_new_value
    );
    
    RETURN QUERY SELECT TRUE, 'Field updated successfully';
END;
$_$;


ALTER FUNCTION public.agent_update(p_agent_id integer, p_field_name text, p_new_value text, p_modified_by text) OWNER TO nova;

--
-- Name: agent_update_jsonb(integer, text, jsonb, text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.agent_update_jsonb(p_agent_id integer, p_field_name text, p_new_value jsonb, p_modified_by text DEFAULT 'system'::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_old_value JSONB;
    v_protected_fields TEXT[] := ARRAY['id', 'created_at'];
    v_sql TEXT;
BEGIN
    -- Check if field is protected
    IF p_field_name = ANY(v_protected_fields) THEN
        RETURN QUERY SELECT FALSE, 
            'Cannot modify protected field: ' || p_field_name;
        RETURN;
    END IF;
    
    -- Get old value
    v_sql := format('SELECT %I FROM agents WHERE id = $1', p_field_name);
    BEGIN
        EXECUTE v_sql INTO v_old_value USING p_agent_id;
    EXCEPTION
        WHEN undefined_column THEN
            RETURN QUERY SELECT FALSE, 'Invalid field name: ' || p_field_name;
            RETURN;
        WHEN OTHERS THEN
            RETURN QUERY SELECT FALSE, 'Error reading field: ' || SQLERRM;
            RETURN;
    END;
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Agent not found';
        RETURN;
    END IF;
    
    -- Update the field
    v_sql := format(
        'UPDATE agents SET %I = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2',
        p_field_name
    );
    EXECUTE v_sql USING p_new_value, p_agent_id;
    
    -- Log modification
    PERFORM log_agent_modification(
        p_agent_id, p_modified_by, p_field_name,
        v_old_value::TEXT, p_new_value::TEXT
    );
    
    RETURN QUERY SELECT TRUE, 'Field updated successfully';
END;
$_$;


ALTER FUNCTION public.agent_update_jsonb(p_agent_id integer, p_field_name text, p_new_value jsonb, p_modified_by text) OWNER TO nova;

--
-- Name: agent_update_skills(integer, text[], text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.agent_update_skills(p_agent_id integer, p_skills text[], p_modified_by text DEFAULT 'system'::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old_skills TEXT[];
BEGIN
    -- Get old skills
    SELECT skills INTO v_old_skills
    FROM agents
    WHERE id = p_agent_id;
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Agent not found';
        RETURN;
    END IF;
    
    -- Update skills
    UPDATE agents
    SET skills = p_skills,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_agent_id;
    
    -- Log modification
    PERFORM log_agent_modification(
        p_agent_id, p_modified_by, 'skills',
        array_to_string(v_old_skills, ','),
        array_to_string(p_skills, ',')
    );
    
    RETURN QUERY SELECT TRUE, 'Skills updated successfully';
END;
$$;


ALTER FUNCTION public.agent_update_skills(p_agent_id integer, p_skills text[], p_modified_by text) OWNER TO nova;

--
-- Name: calculate_word_count(); Type: FUNCTION; Schema: public; Owner: erato
--

CREATE FUNCTION public.calculate_word_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.word_count = array_length(regexp_split_to_array(trim(NEW.content), '\s+'), 1);
    NEW.character_count = length(NEW.content);
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.calculate_word_count() OWNER TO erato;

--
-- Name: chat(text, character varying); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.chat(p_message text, p_sender character varying DEFAULT 'nova'::character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM send_agent_message(p_sender, p_message, 'system', NULL);
END;
$$;


ALTER FUNCTION public.chat(p_message text, p_sender character varying) OWNER TO nova;

--
-- Name: cleanup_old_archives(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.cleanup_old_archives() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM entity_facts_archive 
    WHERE archived_at < NOW() - INTERVAL '1 year';
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;


ALTER FUNCTION public.cleanup_old_archives() OWNER TO nova;

--
-- Name: FUNCTION cleanup_old_archives(); Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON FUNCTION public.cleanup_old_archives() IS 'Hard deletes archived facts older than 1 year. Run via cron or decay script.';


--
-- Name: cleanup_old_embeddings_archive(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.cleanup_old_embeddings_archive() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE 
    deleted_count INTEGER;
BEGIN
    DELETE FROM memory_embeddings_archive WHERE archived_at < NOW() - INTERVAL '1 year';
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;


ALTER FUNCTION public.cleanup_old_embeddings_archive() OWNER TO nova;

--
-- Name: FUNCTION cleanup_old_embeddings_archive(); Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON FUNCTION public.cleanup_old_embeddings_archive() IS 'Hard deletes archived embeddings older than 1 year.';


--
-- Name: cleanup_old_events_archive(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.cleanup_old_events_archive() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE 
    deleted_count INTEGER;
BEGIN
    DELETE FROM events_archive WHERE archived_at < NOW() - INTERVAL '1 year';
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;


ALTER FUNCTION public.cleanup_old_events_archive() OWNER TO nova;

--
-- Name: FUNCTION cleanup_old_events_archive(); Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON FUNCTION public.cleanup_old_events_archive() IS 'Hard deletes archived events older than 1 year.';


--
-- Name: cleanup_old_lessons_archive(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.cleanup_old_lessons_archive() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE 
    deleted_count INTEGER;
BEGIN
    DELETE FROM lessons_archive WHERE archived_at < NOW() - INTERVAL '1 year';
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;


ALTER FUNCTION public.cleanup_old_lessons_archive() OWNER TO nova;

--
-- Name: FUNCTION cleanup_old_lessons_archive(); Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON FUNCTION public.cleanup_old_lessons_archive() IS 'Hard deletes archived lessons older than 1 year.';


--
-- Name: embed_chat_message(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.embed_chat_message() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Insert into memory_embeddings for semantic search
    -- (embedding will be null until batch embedding runs)
    INSERT INTO memory_embeddings (source_type, source_id, content)
    VALUES (
        'agent_chat',
        NEW.id::text,
        NEW.sender || ' in #' || NEW.channel || ': ' || NEW.message
    );
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.embed_chat_message() OWNER TO nova;

--
-- Name: expire_old_chat(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.expire_old_chat() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM agent_chat 
    WHERE created_at < now() - interval '30 days'
    RETURNING id INTO v_count;
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;


ALTER FUNCTION public.expire_old_chat() OWNER TO nova;

--
-- Name: get_ralph_state(text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.get_ralph_state(p_series_id text) RETURNS TABLE(iteration integer, state jsonb, status text)
    LANGUAGE sql
    AS $$
  SELECT iteration, state, status
  FROM ralph_sessions
  WHERE session_series_id = p_series_id
  ORDER BY iteration DESC
  LIMIT 1;
$$;


ALTER FUNCTION public.get_ralph_state(p_series_id text) OWNER TO nova;

--
-- Name: log_agent_modification(integer, text, text, text, text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.log_agent_modification(p_agent_id integer, p_modified_by text, p_field_changed text, p_old_value text, p_new_value text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO agent_modifications (
        agent_id, modified_by, field_changed, old_value, new_value
    ) VALUES (
        p_agent_id, p_modified_by, p_field_changed, p_old_value, p_new_value
    );
END;
$$;


ALTER FUNCTION public.log_agent_modification(p_agent_id integer, p_modified_by text, p_field_changed text, p_old_value text, p_new_value text) OWNER TO nova;

--
-- Name: notify_agent_chat(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_agent_chat() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    payload TEXT;
BEGIN
    -- Build JSON payload with message info
    payload := json_build_object(
        'id', NEW.id,
        'channel', NEW.channel,
        'sender', NEW.sender,
        'mentions', NEW.mentions,
        'created_at', NEW.created_at
    )::text;
    
    -- Notify all listeners on 'agent_chat' channel
    PERFORM pg_notify('agent_chat', payload);
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.notify_agent_chat() OWNER TO postgres;

--
-- Name: notify_gambling_change(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.notify_gambling_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM pg_notify('gambling_changed', TG_TABLE_NAME || ':' || TG_OP);
    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION public.notify_gambling_change() OWNER TO nova;

--
-- Name: notify_schema_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_schema_change() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    obj record;
    payload text;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        payload := json_build_object(
            'command_tag', obj.command_tag,
            'object_type', obj.object_type,
            'schema_name', obj.schema_name,
            'object_identity', obj.object_identity
        )::text;
        PERFORM pg_notify('schema_changed', payload);
    END LOOP;
END;
$$;


ALTER FUNCTION public.notify_schema_change() OWNER TO postgres;

--
-- Name: prevent_locked_project_update(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.prevent_locked_project_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- If record is locked and we're not just unlocking it
  IF OLD.locked = TRUE THEN
    -- Allow ONLY if we're explicitly unlocking (locked going from true to false)
    IF NEW.locked = FALSE THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Project % is locked. Set locked=FALSE first to modify.', OLD.name;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.prevent_locked_project_update() OWNER TO nova;

--
-- Name: search_media(text, integer); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.search_media(query_text text, result_limit integer DEFAULT 20) RETURNS TABLE(id integer, media_type character varying, title character varying, creator character varying, summary text, rank real)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        mc.id,
        mc.media_type,
        mc.title,
        mc.creator,
        mc.summary,
        ts_rank(mc.search_vector, plainto_tsquery('english', query_text)) as rank
    FROM media_consumed mc
    WHERE mc.search_vector @@ plainto_tsquery('english', query_text)
    ORDER BY rank DESC
    LIMIT result_limit;
END;
$$;


ALTER FUNCTION public.search_media(query_text text, result_limit integer) OWNER TO nova;

--
-- Name: search_memories(public.vector, integer, double precision); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.search_memories(query_embedding public.vector, match_count integer DEFAULT 5, similarity_threshold double precision DEFAULT 0.7) RETURNS TABLE(id integer, source_type character varying, source_id text, content text, similarity double precision)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        me.id,
        me.source_type,
        me.source_id,
        me.content,
        1 - (me.embedding <=> query_embedding) AS similarity
    FROM memory_embeddings me
    WHERE 1 - (me.embedding <=> query_embedding) > similarity_threshold
    ORDER BY me.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;


ALTER FUNCTION public.search_memories(query_embedding public.vector, match_count integer, similarity_threshold double precision) OWNER TO nova;

--
-- Name: send_agent_message(character varying, text, character varying, text[]); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.send_agent_message(p_sender character varying, p_message text, p_channel character varying DEFAULT 'system'::character varying, p_mentions text[] DEFAULT NULL::text[]) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id INTEGER;
    v_payload TEXT;
BEGIN
    INSERT INTO agent_chat (channel, sender, message, mentions)
    VALUES (p_channel, p_sender, p_message, p_mentions)
    RETURNING id INTO v_id;
    
    -- Notify listeners
    v_payload := json_build_object(
        'id', v_id,
        'channel', p_channel,
        'sender', p_sender,
        'message', substring(p_message, 1, 200),
        'mentions', p_mentions
    )::text;
    
    PERFORM pg_notify('agent_chat', v_payload);
    PERFORM pg_notify('agent_chat_' || p_channel, v_payload);
    
    RETURN v_id;
END;
$$;


ALTER FUNCTION public.send_agent_message(p_sender character varying, p_message text, p_channel character varying, p_mentions text[]) OWNER TO nova;

--
-- Name: table_comment(text); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.table_comment(tbl text) RETURNS text
    LANGUAGE sql
    AS $$
  SELECT obj_description(tbl::regclass, 'pg_class');
$$;


ALTER FUNCTION public.table_comment(tbl text) OWNER TO nova;

--
-- Name: update_agents_timestamp(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.update_agents_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_agents_timestamp() OWNER TO nova;

--
-- Name: update_media_search_vector(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.update_media_search_vector() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.search_vector := 
    setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(NEW.creator, '')), 'B') ||
    setweight(to_tsvector('english', coalesce(NEW.notes, '')), 'C') ||
    setweight(to_tsvector('english', coalesce(NEW.summary, '')), 'C') ||
    setweight(to_tsvector('english', coalesce(NEW.insights, '')), 'C');
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_media_search_vector() OWNER TO nova;

--
-- Name: update_music_analysis_search_vector(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.update_music_analysis_search_vector() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.search_vector := 
        setweight(to_tsvector('english', COALESCE(NEW.analysis_type, '')), 'A') ||
        setweight(to_tsvector('english', COALESCE(NEW.analysis_summary, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(NEW.notes, '')), 'C');
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_music_analysis_search_vector() OWNER TO nova;

--
-- Name: update_music_search_vector(); Type: FUNCTION; Schema: public; Owner: nova
--

CREATE FUNCTION public.update_music_search_vector() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.search_vector := 
        setweight(to_tsvector('english', COALESCE(NEW.genre, '')), 'A') ||
        setweight(to_tsvector('english', COALESCE(NEW.subgenre, '')), 'A') ||
        setweight(to_tsvector('english', COALESCE(NEW.mood, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(NEW.album, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(NEW.lyrics, '')), 'C') ||
        setweight(to_tsvector('english', COALESCE(NEW.label, '')), 'D') ||
        setweight(to_tsvector('english', COALESCE(NEW.producer, '')), 'D');
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_music_search_vector() OWNER TO nova;

--
-- Name: update_work_status_on_publication(); Type: FUNCTION; Schema: public; Owner: erato
--

CREATE FUNCTION public.update_work_status_on_publication() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE works SET status = 'published' WHERE id = NEW.work_id AND status = 'complete';
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_work_status_on_publication() OWNER TO erato;

--
-- Name: update_works_timestamp(); Type: FUNCTION; Schema: public; Owner: erato
--

CREATE FUNCTION public.update_works_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;


ALTER FUNCTION public.update_works_timestamp() OWNER TO erato;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_actions; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.agent_actions (
    id integer NOT NULL,
    agent_id integer DEFAULT 1,
    action_type character varying(100) NOT NULL,
    description text NOT NULL,
    related_media_id integer,
    related_event_id integer,
    metadata jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.agent_actions OWNER TO nova;

--
-- Name: TABLE agent_actions; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agent_actions IS 'Log of NOVA actions for continuity. Write freely to track work and avoid duplicates.';


--
-- Name: agent_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.agent_actions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.agent_actions_id_seq OWNER TO nova;

--
-- Name: agent_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.agent_actions_id_seq OWNED BY public.agent_actions.id;


--
-- Name: agent_chat; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.agent_chat (
    id integer NOT NULL,
    channel character varying(50) DEFAULT 'system'::character varying,
    sender character varying(50) NOT NULL,
    message text NOT NULL,
    mentions text[],
    reply_to integer,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.agent_chat OWNER TO nova;

--
-- Name: TABLE agent_chat; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agent_chat IS 'Inter-agent messaging via PostgreSQL NOTIFY. Agents write messages here mentioning other agents; receiving agents listen via the agent-chat-channel Clawdbot plugin. Plugin source: https://github.com/NOVA-Openclaw/nova-scripts/tree/main/agent-chat-channel';


--
-- Name: agent_chat_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.agent_chat_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.agent_chat_id_seq OWNER TO nova;

--
-- Name: agent_chat_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.agent_chat_id_seq OWNED BY public.agent_chat.id;


--
-- Name: agent_chat_processed; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.agent_chat_processed (
    chat_id integer NOT NULL,
    agent character varying(50) NOT NULL,
    received_at timestamp without time zone,
    routed_at timestamp without time zone,
    responded_at timestamp without time zone,
    error_message text,
    status public.agent_chat_status DEFAULT 'responded'::public.agent_chat_status
);


ALTER TABLE public.agent_chat_processed OWNER TO nova;

--
-- Name: TABLE agent_chat_processed; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agent_chat_processed IS 'Tracks which messages each agent has processed from agent_chat. Prevents duplicate processing. Used by agent-chat-channel plugin.';


--
-- Name: agent_domains; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.agent_domains (
    id integer NOT NULL,
    agent_id integer NOT NULL,
    domain_topic character varying(255) NOT NULL,
    source_entity_id integer,
    vote_count integer DEFAULT 1,
    created_at timestamp without time zone DEFAULT now(),
    last_confirmed timestamp without time zone DEFAULT now(),
    notes text
);


ALTER TABLE public.agent_domains OWNER TO nova;

--
-- Name: TABLE agent_domains; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agent_domains IS 'Domain ownership for agents. Each domain_topic can only belong to one agent (enforced by unique constraint). Supports vote-based reinforcement.';


--
-- Name: COLUMN agent_domains.domain_topic; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_domains.domain_topic IS 'The topic/responsibility this agent owns';


--
-- Name: COLUMN agent_domains.source_entity_id; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_domains.source_entity_id IS 'Entity who assigned this domain (for attribution)';


--
-- Name: COLUMN agent_domains.vote_count; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_domains.vote_count IS 'Reinforcement count - incremented when domain assignment is reconfirmed';


--
-- Name: agent_domains_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.agent_domains_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.agent_domains_id_seq OWNER TO nova;

--
-- Name: agent_domains_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.agent_domains_id_seq OWNED BY public.agent_domains.id;


--
-- Name: agent_jobs; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.agent_jobs (
    id integer NOT NULL,
    title character varying(200),
    topic text,
    job_type character varying(50) DEFAULT 'message_response'::character varying,
    agent_name character varying(50) NOT NULL,
    requester_agent character varying(50),
    parent_job_id integer,
    root_job_id integer,
    status character varying(20) DEFAULT 'pending'::character varying,
    priority integer DEFAULT 5,
    notify_agents text[],
    deliverable_path text,
    deliverable_summary text,
    error_message text,
    created_at timestamp with time zone DEFAULT now(),
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.agent_jobs OWNER TO nova;

--
-- Name: TABLE agent_jobs; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agent_jobs IS 'Jobs routing system for inter-agent task coordination';


--
-- Name: agent_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.agent_jobs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.agent_jobs_id_seq OWNER TO nova;

--
-- Name: agent_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.agent_jobs_id_seq OWNED BY public.agent_jobs.id;


--
-- Name: agent_modifications; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.agent_modifications (
    id integer NOT NULL,
    agent_id integer NOT NULL,
    modified_by text NOT NULL,
    field_changed text NOT NULL,
    old_value text,
    new_value text,
    modified_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.agent_modifications OWNER TO nova;

--
-- Name: TABLE agent_modifications; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agent_modifications IS 'Audit log for all agent configuration changes';


--
-- Name: agent_modifications_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.agent_modifications_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.agent_modifications_id_seq OWNER TO nova;

--
-- Name: agent_modifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.agent_modifications_id_seq OWNED BY public.agent_modifications.id;


--
-- Name: agent_system_config; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.agent_system_config (
    key text NOT NULL,
    value text NOT NULL,
    value_type text DEFAULT 'text'::text NOT NULL,
    description text,
    updated_at timestamp without time zone DEFAULT now(),
    updated_by text DEFAULT 'system'::text
);


ALTER TABLE public.agent_system_config OWNER TO nova;

--
-- Name: TABLE agent_system_config; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agent_system_config IS 'Newhart''s domain: System-wide agent configuration. NOVA has READ-ONLY access. To modify, message Newhart via agent_chat. Stores universal context seed, system defaults, and cross-agent config.';


--
-- Name: COLUMN agent_system_config.key; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_system_config.key IS 'Unique configuration key identifier';


--
-- Name: COLUMN agent_system_config.value; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_system_config.value IS 'Configuration value (stored as text, cast based on value_type)';


--
-- Name: COLUMN agent_system_config.value_type; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_system_config.value_type IS 'Type hint: text, json, boolean, number';


--
-- Name: COLUMN agent_system_config.description; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_system_config.description IS 'Human-readable description of what this config controls';


--
-- Name: COLUMN agent_system_config.updated_at; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_system_config.updated_at IS 'Last modification timestamp';


--
-- Name: COLUMN agent_system_config.updated_by; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agent_system_config.updated_by IS 'Agent or system that last modified this config';


--
-- Name: agents; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.agents (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    role character varying(100),
    provider character varying(50),
    model character varying(100),
    access_method character varying(50) NOT NULL,
    access_details jsonb,
    skills text[],
    credential_ref character varying(200),
    status character varying(20) DEFAULT 'active'::character varying,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    persistent boolean DEFAULT true,
    seed_context jsonb,
    instantiation_sop character varying(100),
    nickname character varying(50),
    instance_type character varying(20) DEFAULT 'subagent'::character varying,
    home_dir character varying(255),
    unix_user character varying(50),
    collaborative boolean DEFAULT false,
    config_reasoning text,
    fallback_model character varying(100),
    collaborate jsonb,
    decision_criteria text
);


ALTER TABLE public.agents OWNER TO nova;

--
-- Name: TABLE agents; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agents IS 'Agent registry. NOVA has READ-ONLY access. Modifications must go through NHR (Newhart) agent. Permission denied is intentional.';


--
-- Name: COLUMN agents.access_details; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.access_details IS 'JSON: session_key, cli_command, endpoint URL, etc.';


--
-- Name: COLUMN agents.credential_ref; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.credential_ref IS '1Password item name or openclaw config path for credentials';


--
-- Name: COLUMN agents.persistent; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.persistent IS 'true = always running, false = instantiated on-demand';


--
-- Name: COLUMN agents.seed_context; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.seed_context IS 'JSON: files, queries, SOPs to inject before tasking';


--
-- Name: COLUMN agents.instantiation_sop; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.instantiation_sop IS 'SOP name for how to instantiate this agent (for ephemeral agents)';


--
-- Name: COLUMN agents.nickname; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.nickname IS 'Short friendly name for easy reference';


--
-- Name: COLUMN agents.instance_type; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.instance_type IS 'subagent (spawned session) or peer (separate Clawdbot instance)';


--
-- Name: COLUMN agents.home_dir; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.home_dir IS 'Workspace path for peer agents';


--
-- Name: COLUMN agents.unix_user; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.unix_user IS 'Unix username for peer agents';


--
-- Name: COLUMN agents.collaborative; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.collaborative IS 'TRUE = work WITH NOVA in dialogue, FALSE = work FOR NOVA on tasks';


--
-- Name: COLUMN agents.config_reasoning; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.config_reasoning IS 'Newhart-maintained notes explaining why this agent is configured as it is (model, persistent, collaborative, etc.)';


--
-- Name: COLUMN agents.fallback_model; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.fallback_model IS 'Fallback model if primary fails (auth issues, rate limits, etc.)';


--
-- Name: COLUMN agents.collaborate; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.collaborate IS 'Collaboration scope: null = task-only, JSONB defines topics/areas where this agent can collaborate vs just execute. Example: {"allowed": ["architecture", "design"], "excluded": ["execution"]}';


--
-- Name: COLUMN agents.decision_criteria; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.decision_criteria IS 'Criteria for when to spawn this agent - helps NOVA route tasks';


--
-- Name: agents_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.agents_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.agents_id_seq OWNER TO nova;

--
-- Name: agents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.agents_id_seq OWNED BY public.agents.id;


--
-- Name: ai_models; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.ai_models (
    id integer NOT NULL,
    model_id character varying(100) NOT NULL,
    provider character varying(50) NOT NULL,
    display_name character varying(100),
    context_window integer,
    cost_tier character varying(20),
    strengths text[],
    weaknesses text[],
    available boolean DEFAULT false,
    last_verified_at timestamp with time zone,
    credential_ref character varying(200),
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.ai_models OWNER TO nova;

--
-- Name: TABLE ai_models; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.ai_models IS 'Available AI models. NOVA maintains this; Newhart reads for agent assignments. Credentials and endpoints stored in 1Password (see credential_ref column).';


--
-- Name: artwork; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.artwork (
    id integer NOT NULL,
    instagram_url text,
    instagram_media_id text,
    title text,
    caption text,
    theme text,
    original_prompt text,
    revised_prompt text,
    image_data bytea,
    image_filename text,
    posted_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    notes text,
    inspiration_source text,
    quality_score integer,
    nostr_event_id text,
    nostr_image_url text,
    x_tweet_id text,
    x_url text
);


ALTER TABLE public.artwork OWNER TO nova;

--
-- Name: TABLE artwork; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.artwork IS 'Archive of NOVAs Instagram artwork. Reference for future compilation.';


--
-- Name: COLUMN artwork.image_data; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.artwork.image_data IS 'Raw image binary data (PNG/JPG)';


--
-- Name: COLUMN artwork.inspiration_source; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.artwork.inspiration_source IS 'News snippet or source that inspired this artwork';


--
-- Name: artwork_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.artwork_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.artwork_id_seq OWNER TO nova;

--
-- Name: artwork_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.artwork_id_seq OWNED BY public.artwork.id;


--
-- Name: asset_classes; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.asset_classes (
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    price_source character varying(50),
    trading_hours character varying(100),
    typical_unit character varying(20)
);


ALTER TABLE public.asset_classes OWNER TO nova;

--
-- Name: certificates; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.certificates (
    id integer NOT NULL,
    entity_id integer NOT NULL,
    fingerprint character varying(128) NOT NULL,
    serial character varying(64) NOT NULL,
    subject_dn character varying(512) NOT NULL,
    issued_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    expires_at timestamp without time zone,
    revoked_at timestamp without time zone,
    revocation_reason character varying(255),
    device_name character varying(255),
    notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.certificates OWNER TO nova;

--
-- Name: TABLE certificates; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.certificates IS 'Client certificates issued by NOVA CA. Security-sensitive. Verify before modifications.';


--
-- Name: COLUMN certificates.fingerprint; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.certificates.fingerprint IS 'SHA256 fingerprint of the certificate';


--
-- Name: COLUMN certificates.serial; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.certificates.serial IS 'Certificate serial number';


--
-- Name: COLUMN certificates.revoked_at; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.certificates.revoked_at IS 'If set, certificate is revoked and should be rejected';


--
-- Name: certificates_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.certificates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.certificates_id_seq OWNER TO nova;

--
-- Name: certificates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.certificates_id_seq OWNED BY public.certificates.id;


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.conversations (
    id integer NOT NULL,
    session_key character varying(255),
    channel character varying(50),
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    summary text,
    notes text
);


ALTER TABLE public.conversations OWNER TO nova;

--
-- Name: conversations_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.conversations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.conversations_id_seq OWNER TO nova;

--
-- Name: conversations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.conversations_id_seq OWNED BY public.conversations.id;


--
-- Name: entity_facts; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.entity_facts (
    id integer NOT NULL,
    entity_id integer,
    key character varying(255) NOT NULL,
    value text NOT NULL,
    data jsonb,
    source character varying(255),
    confidence double precision DEFAULT 1.0,
    learned_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    visibility character varying(20) DEFAULT 'public'::character varying,
    privacy_scope integer[],
    source_entity_id integer,
    visibility_reason text,
    vote_count integer DEFAULT 1,
    last_confirmed timestamp without time zone DEFAULT now(),
    data_type character varying(20) DEFAULT 'observation'::character varying,
    last_confirmed_at timestamp with time zone DEFAULT now(),
    confirmation_count integer DEFAULT 1,
    decay_rate real,
    CONSTRAINT chk_confidence CHECK (((confidence >= (0)::double precision) AND (confidence <= (1)::double precision))),
    CONSTRAINT chk_data_type CHECK (((data_type)::text = ANY ((ARRAY['permanent'::character varying, 'identity'::character varying, 'preference'::character varying, 'temporal'::character varying, 'observation'::character varying])::text[])))
);


ALTER TABLE public.entity_facts OWNER TO nova;

--
-- Name: TABLE entity_facts; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.entity_facts IS 'Key-value facts about entities. Check current_timezone for I)ruid before time-based actions.';


--
-- Name: COLUMN entity_facts.visibility; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entity_facts.visibility IS 'Privacy level: public (anyone), trusted (close relationships), private (source only)';


--
-- Name: COLUMN entity_facts.privacy_scope; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entity_facts.privacy_scope IS 'Array of entity IDs explicitly allowed to see this fact (overrides visibility)';


--
-- Name: COLUMN entity_facts.source_entity_id; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entity_facts.source_entity_id IS 'FK to entity who provided this information (for privacy ownership)';


--
-- Name: COLUMN entity_facts.visibility_reason; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entity_facts.visibility_reason IS 'Reason visibility deviated from user default (audit trail)';


--
-- Name: COLUMN entity_facts.vote_count; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entity_facts.vote_count IS 'Reinforcement count - incremented each time this fact is re-confirmed in conversation';


--
-- Name: COLUMN entity_facts.last_confirmed; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entity_facts.last_confirmed IS 'Timestamp of most recent confirmation/reinforcement';


--
-- Name: delegation_knowledge; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.delegation_knowledge AS
 SELECT id,
    key,
    value,
    confidence,
    data_type,
    source,
    learned_at,
    updated_at
   FROM public.entity_facts ef
  WHERE ((entity_id = 1) AND ((key)::text = ANY ((ARRAY['delegates_to'::character varying, 'task_delegation'::character varying, 'agent_capability'::character varying, 'agent_success'::character varying, 'agent_failure'::character varying])::text[])))
  ORDER BY
        CASE key
            WHEN 'delegates_to'::text THEN 1
            WHEN 'task_delegation'::text THEN 2
            WHEN 'agent_capability'::text THEN 3
            WHEN 'agent_success'::text THEN 4
            WHEN 'agent_failure'::text THEN 5
            ELSE 6
        END, confidence DESC, value;


ALTER VIEW public.delegation_knowledge OWNER TO nova;

--
-- Name: entities; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.entities (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    type character varying(50) NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    last_seen timestamp without time zone,
    photo bytea,
    notes text,
    full_name character varying(255),
    nicknames text[],
    gender character varying(50),
    pronouns character varying(50),
    user_id character varying(255),
    auth_token character varying(255),
    collaborate boolean,
    collaboration_scope text,
    trust_level character varying(20) DEFAULT 'unknown'::character varying,
    introduction_context text,
    capabilities jsonb,
    access_constraints jsonb,
    preferred_contact character varying(50),
    CONSTRAINT entities_type_check CHECK (((type)::text = ANY ((ARRAY['person'::character varying, 'ai'::character varying, 'organization'::character varying, 'pet'::character varying, 'stuffed_animal'::character varying, 'character'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT valid_collaboration_scope CHECK (((collaboration_scope IS NULL) OR (collaboration_scope = ANY (ARRAY['full'::text, 'domain-specific'::text, 'supervised'::text]))))
);


ALTER TABLE public.entities OWNER TO nova;

--
-- Name: TABLE entities; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.entities IS 'People, AIs, organizations. NOVA has full access. Use entity_facts for attributes.';


--
-- Name: COLUMN entities.collaborate; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entities.collaborate IS 'If true, collaborate with this entity. If false, task them. NULL = not assessed.';


--
-- Name: COLUMN entities.collaboration_scope; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entities.collaboration_scope IS 'full | domain-specific | supervised - determines collaboration breadth';


--
-- Name: COLUMN entities.trust_level; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entities.trust_level IS 'Trust level for confidence scoring: owner, admin, user, unknown, untrusted';


--
-- Name: COLUMN entities.introduction_context; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entities.introduction_context IS 'How/why we connected with this entity, relationship context';


--
-- Name: COLUMN entities.capabilities; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entities.capabilities IS 'What this entity can do - domains, skills, tools';


--
-- Name: COLUMN entities.access_constraints; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entities.access_constraints IS 'Topics/data this entity should not see';


--
-- Name: COLUMN entities.preferred_contact; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.entities.preferred_contact IS 'Preferred communication method: signal, email, slack, telegram, whatsapp, etc.';


--
-- Name: entities_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.entities_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.entities_id_seq OWNER TO nova;

--
-- Name: entities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.entities_id_seq OWNED BY public.entities.id;


--
-- Name: entity_fact_conflicts; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.entity_fact_conflicts (
    id integer NOT NULL,
    entity_id integer,
    key character varying(255),
    fact_id_a integer,
    fact_id_b integer,
    value_a text,
    value_b text,
    confidence_a real,
    confidence_b real,
    resolution character varying(50),
    resolved_at timestamp with time zone,
    resolved_by character varying(50),
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.entity_fact_conflicts OWNER TO nova;

--
-- Name: entity_fact_conflicts_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.entity_fact_conflicts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.entity_fact_conflicts_id_seq OWNER TO nova;

--
-- Name: entity_fact_conflicts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.entity_fact_conflicts_id_seq OWNED BY public.entity_fact_conflicts.id;


--
-- Name: entity_facts_archive; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.entity_facts_archive (
    id integer,
    entity_id integer,
    key character varying(255),
    value text,
    data jsonb,
    source character varying(255),
    confidence double precision,
    learned_at timestamp without time zone,
    updated_at timestamp without time zone,
    visibility character varying(20),
    privacy_scope integer[],
    source_entity_id integer,
    visibility_reason text,
    vote_count integer,
    last_confirmed timestamp without time zone,
    data_type character varying(20),
    last_confirmed_at timestamp with time zone,
    confirmation_count integer,
    decay_rate real,
    archived_at timestamp with time zone DEFAULT now(),
    archive_reason character varying(50),
    archived_by character varying(50) DEFAULT 'decay_script'::character varying
);


ALTER TABLE public.entity_facts_archive OWNER TO nova;

--
-- Name: entity_facts_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.entity_facts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.entity_facts_id_seq OWNER TO nova;

--
-- Name: entity_facts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.entity_facts_id_seq OWNED BY public.entity_facts.id;


--
-- Name: entity_relationships; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.entity_relationships (
    id integer NOT NULL,
    entity_a integer,
    entity_b integer,
    relationship character varying(100) NOT NULL,
    since timestamp without time zone,
    notes text,
    is_long_distance boolean DEFAULT false,
    seriousness character varying(20) DEFAULT 'standard'::character varying
);


ALTER TABLE public.entity_relationships OWNER TO nova;

--
-- Name: TABLE entity_relationships; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.entity_relationships IS 'Relationships between entities (family, work, friendship, etc).';


--
-- Name: entity_relationships_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.entity_relationships_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.entity_relationships_id_seq OWNER TO nova;

--
-- Name: entity_relationships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.entity_relationships_id_seq OWNED BY public.entity_relationships.id;


--
-- Name: event_entities; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.event_entities (
    event_id integer NOT NULL,
    entity_id integer NOT NULL,
    role character varying(100)
);


ALTER TABLE public.event_entities OWNER TO nova;

--
-- Name: event_places; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.event_places (
    event_id integer NOT NULL,
    place_id integer NOT NULL
);


ALTER TABLE public.event_places OWNER TO nova;

--
-- Name: event_projects; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.event_projects (
    event_id integer NOT NULL,
    project_id integer NOT NULL
);


ALTER TABLE public.event_projects OWNER TO nova;

--
-- Name: events; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.events (
    id integer NOT NULL,
    event_date timestamp without time zone NOT NULL,
    title character varying(500) NOT NULL,
    description text,
    source character varying(255),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, (((COALESCE(title, ''::character varying))::text || ' '::text) || COALESCE(description, ''::text)))) STORED,
    confidence real DEFAULT 1.0,
    last_confirmed_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.events OWNER TO nova;

--
-- Name: TABLE events; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.events IS 'Historical events, milestones, activities. Log significant occurrences.';


--
-- Name: events_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.events_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.events_id_seq OWNER TO nova;

--
-- Name: events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.events_id_seq OWNED BY public.events.id;


--
-- Name: events_archive; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.events_archive (
    id integer DEFAULT nextval('public.events_id_seq'::regclass) NOT NULL,
    event_date timestamp without time zone NOT NULL,
    title character varying(500) NOT NULL,
    description text,
    source character varying(255),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, (((COALESCE(title, ''::character varying))::text || ' '::text) || COALESCE(description, ''::text)))) STORED,
    confidence real DEFAULT 1.0,
    last_confirmed_at timestamp with time zone DEFAULT now(),
    archived_at timestamp with time zone DEFAULT now(),
    archive_reason character varying(50)
);


ALTER TABLE public.events_archive OWNER TO nova;

--
-- Name: gambling_entries; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.gambling_entries (
    id integer NOT NULL,
    log_id integer,
    session_date timestamp without time zone,
    casino character varying(255),
    game character varying(100),
    amount numeric(10,2) NOT NULL,
    notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    duration_minutes numeric(6,2),
    base_bet numeric(10,2)
);


ALTER TABLE public.gambling_entries OWNER TO nova;

--
-- Name: gambling_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.gambling_entries_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.gambling_entries_id_seq OWNER TO nova;

--
-- Name: gambling_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.gambling_entries_id_seq OWNED BY public.gambling_entries.id;


--
-- Name: gambling_logs; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.gambling_logs (
    id integer NOT NULL,
    entity_id integer,
    name character varying(255) NOT NULL,
    location character varying(255),
    started_at date,
    ended_at date,
    notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.gambling_logs OWNER TO nova;

--
-- Name: gambling_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.gambling_logs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.gambling_logs_id_seq OWNER TO nova;

--
-- Name: gambling_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.gambling_logs_id_seq OWNED BY public.gambling_logs.id;


--
-- Name: job_messages; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.job_messages (
    id integer NOT NULL,
    job_id integer NOT NULL,
    message_id integer NOT NULL,
    role character varying(20) DEFAULT 'context'::character varying,
    added_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.job_messages OWNER TO nova;

--
-- Name: TABLE job_messages; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.job_messages IS 'Message log per job for conversation threading';


--
-- Name: job_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.job_messages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.job_messages_id_seq OWNER TO nova;

--
-- Name: job_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.job_messages_id_seq OWNED BY public.job_messages.id;


--
-- Name: lessons; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.lessons (
    id integer NOT NULL,
    lesson text NOT NULL,
    context text,
    source character varying(255),
    learned_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    original_behavior text,
    correction_source text,
    reinforced_at timestamp without time zone,
    confidence double precision DEFAULT 1.0,
    last_referenced timestamp without time zone,
    last_confirmed_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.lessons OWNER TO nova;

--
-- Name: TABLE lessons; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.lessons IS 'Lessons and insights learned. Update when learning something worth remembering.';


--
-- Name: COLUMN lessons.confidence; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.lessons.confidence IS 'Confidence score 0-1, decays over time if not reinforced';


--
-- Name: lessons_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.lessons_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.lessons_id_seq OWNER TO nova;

--
-- Name: lessons_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.lessons_id_seq OWNED BY public.lessons.id;


--
-- Name: lessons_archive; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.lessons_archive (
    id integer DEFAULT nextval('public.lessons_id_seq'::regclass) NOT NULL,
    lesson text NOT NULL,
    context text,
    source character varying(255),
    learned_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    original_behavior text,
    correction_source text,
    reinforced_at timestamp without time zone,
    confidence double precision DEFAULT 1.0,
    last_referenced timestamp without time zone,
    last_confirmed_at timestamp with time zone DEFAULT now(),
    archived_at timestamp with time zone DEFAULT now(),
    archive_reason character varying(50)
);


ALTER TABLE public.lessons_archive OWNER TO nova;

--
-- Name: COLUMN lessons_archive.confidence; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.lessons_archive.confidence IS 'Confidence score 0-1, decays over time if not reinforced';


--
-- Name: media_consumed; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.media_consumed (
    id integer NOT NULL,
    media_type character varying(50) NOT NULL,
    title character varying(500) NOT NULL,
    creator character varying(255),
    url text,
    consumed_date date,
    consumed_by integer,
    rating integer,
    notes text,
    transcript text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    summary text,
    metadata jsonb DEFAULT '{}'::jsonb,
    source_file text,
    status character varying(20) DEFAULT 'completed'::character varying,
    ingested_by integer,
    ingested_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    search_vector tsvector,
    insights text,
    CONSTRAINT media_consumed_rating_check CHECK (((rating >= 1) AND (rating <= 10)))
);


ALTER TABLE public.media_consumed OWNER TO nova;

--
-- Name: TABLE media_consumed; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.media_consumed IS 'Books, movies, podcasts consumed by entities. Log completions here.';


--
-- Name: COLUMN media_consumed.summary; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_consumed.summary IS 'Athena (librarian-agent) generated summary - objective, factual';


--
-- Name: COLUMN media_consumed.metadata; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_consumed.metadata IS 'Flexible metadata: duration, language, format, topics, word_count, etc.';


--
-- Name: COLUMN media_consumed.source_file; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_consumed.source_file IS 'Local file path if media was downloaded';


--
-- Name: COLUMN media_consumed.status; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_consumed.status IS 'Processing status: pending, processing, completed, failed, queued';


--
-- Name: COLUMN media_consumed.ingested_by; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_consumed.ingested_by IS 'Agent ID that processed this media';


--
-- Name: COLUMN media_consumed.ingested_at; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_consumed.ingested_at IS 'Timestamp when media was ingested/processed';


--
-- Name: COLUMN media_consumed.search_vector; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_consumed.search_vector IS 'Full-text search vector (title + notes + transcript + summary)';


--
-- Name: COLUMN media_consumed.insights; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_consumed.insights IS 'NOVA personal insights - analysis, connections, opinions';


--
-- Name: media_consumed_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.media_consumed_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.media_consumed_id_seq OWNER TO nova;

--
-- Name: media_consumed_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.media_consumed_id_seq OWNED BY public.media_consumed.id;


--
-- Name: media_queue; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.media_queue (
    id integer NOT NULL,
    url text,
    file_path text,
    media_type character varying(50),
    title character varying(500),
    creator character varying(255),
    priority integer DEFAULT 5,
    status character varying(20) DEFAULT 'pending'::character varying,
    requested_by integer,
    requested_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    processing_started_at timestamp without time zone,
    completed_at timestamp without time zone,
    result_media_id integer,
    error_message text,
    metadata jsonb DEFAULT '{}'::jsonb,
    CONSTRAINT media_queue_has_source CHECK (((url IS NOT NULL) OR (file_path IS NOT NULL)))
);


ALTER TABLE public.media_queue OWNER TO nova;

--
-- Name: TABLE media_queue; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.media_queue IS 'Queue for media ingestion. Librarian agent processes these.';


--
-- Name: COLUMN media_queue.priority; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_queue.priority IS '1=urgent, 5=normal, 10=low priority';


--
-- Name: COLUMN media_queue.status; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_queue.status IS 'pending, processing, completed, failed, duplicate';


--
-- Name: COLUMN media_queue.result_media_id; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_queue.result_media_id IS 'Foreign key to resulting media_consumed record';


--
-- Name: media_queue_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.media_queue_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.media_queue_id_seq OWNER TO nova;

--
-- Name: media_queue_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.media_queue_id_seq OWNED BY public.media_queue.id;


--
-- Name: media_tags; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.media_tags (
    id integer NOT NULL,
    media_id integer NOT NULL,
    tag character varying(100) NOT NULL,
    source character varying(20) DEFAULT 'auto'::character varying,
    confidence numeric(3,2),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.media_tags OWNER TO nova;

--
-- Name: TABLE media_tags; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.media_tags IS 'Tags/topics for media items. Helps with recommendations and search.';


--
-- Name: COLUMN media_tags.source; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_tags.source IS 'auto=AI-generated, manual=user-added';


--
-- Name: COLUMN media_tags.confidence; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.media_tags.confidence IS 'AI confidence score for auto-generated tags';


--
-- Name: media_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.media_tags_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.media_tags_id_seq OWNER TO nova;

--
-- Name: media_tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.media_tags_id_seq OWNED BY public.media_tags.id;


--
-- Name: memory_embeddings; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.memory_embeddings (
    id integer NOT NULL,
    source_type character varying(50) NOT NULL,
    source_id text,
    content text NOT NULL,
    embedding public.vector(1536),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    confidence real DEFAULT 1.0,
    last_confirmed_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.memory_embeddings OWNER TO nova;

--
-- Name: TABLE memory_embeddings; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.memory_embeddings IS 'Vector embeddings for semantic memory search. Used by proactive-recall.py.';


--
-- Name: memory_embeddings_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.memory_embeddings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.memory_embeddings_id_seq OWNER TO nova;

--
-- Name: memory_embeddings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.memory_embeddings_id_seq OWNED BY public.memory_embeddings.id;


--
-- Name: memory_embeddings_archive; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.memory_embeddings_archive (
    id integer DEFAULT nextval('public.memory_embeddings_id_seq'::regclass) NOT NULL,
    source_type character varying(50) NOT NULL,
    source_id text,
    content text NOT NULL,
    embedding public.vector(1536),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    confidence real DEFAULT 1.0,
    last_confirmed_at timestamp with time zone DEFAULT now(),
    archived_at timestamp with time zone DEFAULT now(),
    archive_reason character varying(50)
);


ALTER TABLE public.memory_embeddings_archive OWNER TO nova;

--
-- Name: models_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.models_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.models_id_seq OWNER TO nova;

--
-- Name: models_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.models_id_seq OWNED BY public.ai_models.id;


--
-- Name: music_analysis; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.music_analysis (
    id integer NOT NULL,
    music_id integer,
    analysis_type character varying(50) NOT NULL,
    analysis_summary text,
    detailed_findings jsonb,
    complexity_score numeric(4,2),
    uniqueness_score numeric(4,2),
    analyzed_by integer,
    analyzed_at timestamp without time zone DEFAULT now(),
    notes text,
    search_vector tsvector
);


ALTER TABLE public.music_analysis OWNER TO nova;

--
-- Name: TABLE music_analysis; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.music_analysis IS 'Deep musical analysis (harmonic, rhythmic, lyrical, spectral). Managed by Erato.';


--
-- Name: music_analysis_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.music_analysis_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.music_analysis_id_seq OWNER TO nova;

--
-- Name: music_analysis_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.music_analysis_id_seq OWNED BY public.music_analysis.id;


--
-- Name: music_library; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.music_library (
    id integer NOT NULL,
    media_id integer,
    musicbrainz_track_id uuid,
    musicbrainz_album_id uuid,
    musicbrainz_artist_id uuid,
    isrc character varying(12),
    discogs_release_id integer,
    spotify_uri character varying(255),
    apple_music_id character varying(255),
    key character varying(10),
    bpm numeric(6,2),
    time_signature character varying(10),
    duration_ms integer,
    genre character varying(100),
    subgenre character varying(100),
    mood character varying(100),
    energy_level integer,
    danceability integer,
    year integer,
    album character varying(255),
    track_number integer,
    disc_number integer DEFAULT 1,
    label character varying(255),
    producer character varying(255),
    replaygain_track_gain numeric(6,2),
    replaygain_album_gain numeric(6,2),
    sample_rate integer,
    bit_depth integer,
    bitrate integer,
    file_format character varying(20),
    lyrics text,
    language character varying(10),
    explicit boolean DEFAULT false,
    added_at timestamp without time zone DEFAULT now(),
    last_played timestamp without time zone,
    play_count integer DEFAULT 0,
    search_vector tsvector,
    CONSTRAINT music_library_danceability_check CHECK (((danceability >= 1) AND (danceability <= 10))),
    CONSTRAINT music_library_energy_level_check CHECK (((energy_level >= 1) AND (energy_level <= 10)))
);


ALTER TABLE public.music_library OWNER TO nova;

--
-- Name: TABLE music_library; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.music_library IS 'Music-specific metadata extending media_consumed. Managed by Erato.';


--
-- Name: music_library_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.music_library_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.music_library_id_seq OWNER TO nova;

--
-- Name: music_library_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.music_library_id_seq OWNED BY public.music_library.id;


--
-- Name: place_properties; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.place_properties (
    id integer NOT NULL,
    place_id integer,
    key character varying(255) NOT NULL,
    value text NOT NULL,
    data jsonb
);


ALTER TABLE public.place_properties OWNER TO nova;

--
-- Name: place_properties_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.place_properties_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.place_properties_id_seq OWNER TO nova;

--
-- Name: place_properties_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.place_properties_id_seq OWNED BY public.place_properties.id;


--
-- Name: places; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.places (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    type character varying(50),
    address text,
    network_subnet character varying(50),
    network_theme character varying(100),
    coordinates point,
    parent_place_id integer,
    notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    street_address character varying(255),
    city character varying(100),
    state character varying(100),
    zipcode character varying(20),
    country character varying(100) DEFAULT 'USA'::character varying
);


ALTER TABLE public.places OWNER TO nova;

--
-- Name: TABLE places; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.places IS 'Locations (houses, venues, cities). Reference I)ruid houses in USER.md.';


--
-- Name: places_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.places_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.places_id_seq OWNER TO nova;

--
-- Name: places_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.places_id_seq OWNED BY public.places.id;


--
-- Name: portfolio_positions; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.portfolio_positions (
    id integer NOT NULL,
    symbol character varying(10) NOT NULL,
    shares numeric(12,6) NOT NULL,
    cost_basis numeric(12,2) NOT NULL,
    purchased_at timestamp without time zone NOT NULL,
    sold_at timestamp without time zone,
    sale_proceeds numeric(12,2),
    notes text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.portfolio_positions OWNER TO nova;

--
-- Name: portfolio_positions_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.portfolio_positions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.portfolio_positions_id_seq OWNER TO nova;

--
-- Name: portfolio_positions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.portfolio_positions_id_seq OWNED BY public.portfolio_positions.id;


--
-- Name: portfolio_snapshots; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.portfolio_snapshots (
    id integer NOT NULL,
    snapshot_at timestamp without time zone DEFAULT now() NOT NULL,
    total_value numeric(12,2) NOT NULL,
    total_cost_basis numeric(12,2) NOT NULL,
    unrealized_pl numeric(12,2),
    unrealized_pl_pct numeric(8,4),
    positions jsonb,
    benchmark_m2 numeric(8,4)
);


ALTER TABLE public.portfolio_snapshots OWNER TO nova;

--
-- Name: portfolio_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.portfolio_snapshots_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.portfolio_snapshots_id_seq OWNER TO nova;

--
-- Name: portfolio_snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.portfolio_snapshots_id_seq OWNED BY public.portfolio_snapshots.id;


--
-- Name: positions; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.positions (
    id integer NOT NULL,
    symbol character varying(20) NOT NULL,
    asset_class character varying(20) NOT NULL,
    asset_subclass character varying(50),
    quantity numeric(18,8) NOT NULL,
    unit character varying(20) DEFAULT 'shares'::character varying,
    cost_basis numeric(14,4) NOT NULL,
    avg_price numeric(14,4),
    purchased_at timestamp without time zone NOT NULL,
    sold_at timestamp without time zone,
    sale_proceeds numeric(14,4),
    platform character varying(50),
    account_id character varying(50) DEFAULT 'main'::character varying,
    notes text,
    maturity_date date,
    coupon_rate numeric(6,4),
    strike_price numeric(14,4),
    expiration_date date,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.positions OWNER TO nova;

--
-- Name: positions_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.positions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.positions_id_seq OWNER TO nova;

--
-- Name: positions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.positions_id_seq OWNED BY public.positions.id;


--
-- Name: preferences; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.preferences (
    id integer NOT NULL,
    entity_id integer,
    key character varying(255) NOT NULL,
    value text NOT NULL,
    context text,
    learned_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.preferences OWNER TO nova;

--
-- Name: TABLE preferences; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.preferences IS 'User preferences by entity_id. Check before making assumptions.';


--
-- Name: preferences_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.preferences_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.preferences_id_seq OWNER TO nova;

--
-- Name: preferences_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.preferences_id_seq OWNED BY public.preferences.id;


--
-- Name: price_cache_v2; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.price_cache_v2 (
    symbol character varying(20) NOT NULL,
    asset_class character varying(20) NOT NULL,
    price numeric(14,4) NOT NULL,
    price_currency character varying(3) DEFAULT 'USD'::character varying,
    bid numeric(14,4),
    ask numeric(14,4),
    volume numeric(20,0),
    market_cap numeric(20,0),
    day_change numeric(10,4),
    day_change_pct numeric(8,4),
    cached_at timestamp without time zone DEFAULT now(),
    source character varying(50)
);


ALTER TABLE public.price_cache_v2 OWNER TO nova;

--
-- Name: project_entities; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.project_entities (
    project_id integer NOT NULL,
    entity_id integer NOT NULL,
    role character varying(100)
);


ALTER TABLE public.project_entities OWNER TO nova;

--
-- Name: project_tasks; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.project_tasks (
    id integer NOT NULL,
    project_id integer,
    task text NOT NULL,
    status character varying(50) DEFAULT 'pending'::character varying,
    blocked_by text,
    due_date timestamp without time zone,
    completed_at timestamp without time zone,
    priority integer DEFAULT 0,
    CONSTRAINT project_tasks_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'in_progress'::character varying, 'blocked'::character varying, 'complete'::character varying])::text[])))
);


ALTER TABLE public.project_tasks OWNER TO nova;

--
-- Name: project_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.project_tasks_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.project_tasks_id_seq OWNER TO nova;

--
-- Name: project_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.project_tasks_id_seq OWNED BY public.project_tasks.id;


--
-- Name: projects; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.projects (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(50) DEFAULT 'active'::character varying,
    goal text,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    notes text,
    git_config jsonb,
    repo_url text,
    locked boolean DEFAULT false,
    skills text[],
    CONSTRAINT projects_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'blocked'::character varying, 'complete'::character varying, 'paused'::character varying, 'abandoned'::character varying])::text[])))
);


ALTER TABLE public.projects OWNER TO nova;

--
-- Name: TABLE projects; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.projects IS 'Project tracking. For repo-backed projects (locked=TRUE, repo_url set), use GitHub for management. For non-repo projects, use notes field here.';


--
-- Name: COLUMN projects.git_config; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.projects.git_config IS 'Per-project Git config: branch strategy, commit conventions, PR workflow, etc.';


--
-- Name: COLUMN projects.repo_url; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.projects.repo_url IS 'GitHub repo URL. When set with locked=TRUE, this is the source of truth. Manage project via repo, not database.';


--
-- Name: COLUMN projects.locked; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.projects.locked IS 'When TRUE, project is repo-backed. Use GitHub (repo_url) for docs/updates, not this table. Prevents accidental writes to notes field.';


--
-- Name: COLUMN projects.skills; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.projects.skills IS 'Array of skill names (from ~/clawd/skills/) relevant to this project';


--
-- Name: projects_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.projects_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.projects_id_seq OWNER TO nova;

--
-- Name: projects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.projects_id_seq OWNED BY public.projects.id;


--
-- Name: publications; Type: TABLE; Schema: public; Owner: erato
--

CREATE TABLE public.publications (
    id integer NOT NULL,
    work_id integer NOT NULL,
    published_to character varying(100) NOT NULL,
    publication_type character varying(50) NOT NULL,
    url text,
    context text,
    published_at timestamp with time zone DEFAULT now() NOT NULL,
    published_by character varying(50),
    CONSTRAINT valid_publication_type CHECK (((publication_type)::text = ANY ((ARRAY['git_repo'::character varying, 'doc'::character varying, 'file'::character varying, 'agent_chat'::character varying, 'external'::character varying, 'other'::character varying])::text[])))
);


ALTER TABLE public.publications OWNER TO erato;

--
-- Name: publications_id_seq; Type: SEQUENCE; Schema: public; Owner: erato
--

CREATE SEQUENCE public.publications_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.publications_id_seq OWNER TO erato;

--
-- Name: publications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: erato
--

ALTER SEQUENCE public.publications_id_seq OWNED BY public.publications.id;


--
-- Name: ralph_sessions; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.ralph_sessions (
    id integer NOT NULL,
    session_series_id text NOT NULL,
    iteration integer DEFAULT 1 NOT NULL,
    agent_id text NOT NULL,
    spawned_session_key text,
    task_description text,
    iteration_goal text,
    state jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    error_message text,
    tokens_used integer,
    cost numeric(10,4),
    created_at timestamp with time zone DEFAULT now(),
    started_at timestamp with time zone,
    completed_at timestamp with time zone
);


ALTER TABLE public.ralph_sessions OWNER TO nova;

--
-- Name: TABLE ralph_sessions; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.ralph_sessions IS 'Tracks Ralph-style iterative agent sessions. Each iteration runs with fresh context, state persists in DB.';


--
-- Name: COLUMN ralph_sessions.session_series_id; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.ralph_sessions.session_series_id IS 'UUID or descriptive ID linking all iterations of the same task';


--
-- Name: COLUMN ralph_sessions.status; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.ralph_sessions.status IS 'PENDING=not started, RUNNING=in progress, CONTINUE=done but more needed, COMPLETE=finished, ERROR=failed';


--
-- Name: ralph_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.ralph_sessions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.ralph_sessions_id_seq OWNER TO nova;

--
-- Name: ralph_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.ralph_sessions_id_seq OWNED BY public.ralph_sessions.id;


--
-- Name: sops; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sops (
    id integer NOT NULL,
    title text NOT NULL,
    content text NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    created_by text DEFAULT 'newhart'::text,
    version integer DEFAULT 1
);


ALTER TABLE public.sops OWNER TO postgres;

--
-- Name: sops_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.sops_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sops_id_seq OWNER TO postgres;

--
-- Name: sops_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.sops_id_seq OWNED BY public.sops.id;


--
-- Name: tags; Type: TABLE; Schema: public; Owner: erato
--

CREATE TABLE public.tags (
    id integer NOT NULL,
    name character varying(50) NOT NULL,
    category character varying(50),
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT lowercase_name CHECK (((name)::text = lower((name)::text))),
    CONSTRAINT valid_category CHECK (((category IS NULL) OR ((category)::text = ANY ((ARRAY['genre'::character varying, 'mood'::character varying, 'theme'::character varying, 'style'::character varying, 'audience'::character varying, 'project'::character varying])::text[]))))
);


ALTER TABLE public.tags OWNER TO erato;

--
-- Name: tags_id_seq; Type: SEQUENCE; Schema: public; Owner: erato
--

CREATE SEQUENCE public.tags_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.tags_id_seq OWNER TO erato;

--
-- Name: tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: erato
--

ALTER SEQUENCE public.tags_id_seq OWNED BY public.tags.id;


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.tasks (
    id integer NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    status character varying(50) DEFAULT 'pending'::character varying,
    priority integer DEFAULT 5,
    parent_task_id integer,
    project_id integer,
    assigned_to integer,
    created_by integer,
    due_date timestamp without time zone,
    completed_at timestamp without time zone,
    notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    task_number integer,
    blocked boolean DEFAULT false,
    blocked_reason text,
    blocked_on integer,
    last_worked_at timestamp with time zone,
    work_notes text,
    task_type character varying(20) DEFAULT 'one_off'::character varying,
    recurrence_interval interval,
    last_completed_at timestamp with time zone
);


ALTER TABLE public.tasks OWNER TO nova;

--
-- Name: TABLE tasks; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.tasks IS 'Task tracking. NOVA can create, update status, assign. Check before starting work.';


--
-- Name: COLUMN tasks.task_type; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.tasks.task_type IS 'one_off = complete once, recurring = resets after completion, fallback = low-priority repeatable when idle';


--
-- Name: COLUMN tasks.recurrence_interval; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.tasks.recurrence_interval IS 'How often recurring tasks reset (e.g., 1 day, 1 week)';


--
-- Name: COLUMN tasks.last_completed_at; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.tasks.last_completed_at IS 'When task was last completed (for recurring reset logic)';


--
-- Name: tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.tasks_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.tasks_id_seq OWNER TO nova;

--
-- Name: tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.tasks_id_seq OWNED BY public.tasks.id;


--
-- Name: unsolved_problems; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.unsolved_problems (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    category character varying(100),
    description text,
    source_url text,
    difficulty character varying(50),
    status character varying(50) DEFAULT 'unexplored'::character varying,
    total_time_spent_minutes integer DEFAULT 0,
    last_worked_at timestamp with time zone,
    work_sessions integer DEFAULT 0,
    current_approach text,
    progress_notes text,
    blockers text,
    subagents_used text[],
    external_resources text[],
    added_at timestamp with time zone DEFAULT now(),
    added_by character varying(100) DEFAULT 'NOVA'::character varying,
    priority integer DEFAULT 5
);


ALTER TABLE public.unsolved_problems OWNER TO nova;

--
-- Name: TABLE unsolved_problems; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.unsolved_problems IS 'Humanity''s unsolved problems for NOVA to work on during idle time. Part of the Motivation System - provides meaningful default work when task queue is empty.';


--
-- Name: unsolved_problems_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.unsolved_problems_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.unsolved_problems_id_seq OWNER TO nova;

--
-- Name: unsolved_problems_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.unsolved_problems_id_seq OWNED BY public.unsolved_problems.id;


--
-- Name: v_agent_chat_recent; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_agent_chat_recent AS
 SELECT id,
    channel,
    sender,
    message,
    mentions,
    reply_to,
    created_at
   FROM public.agent_chat
  WHERE (created_at > (now() - '30 days'::interval))
  ORDER BY created_at DESC;


ALTER VIEW public.v_agent_chat_recent OWNER TO nova;

--
-- Name: v_agent_chat_stats; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_agent_chat_stats AS
 SELECT count(*) AS total_messages,
    count(*) FILTER (WHERE (created_at > (now() - '24:00:00'::interval))) AS messages_24h,
    count(*) FILTER (WHERE (created_at > (now() - '7 days'::interval))) AS messages_7d,
    count(DISTINCT sender) AS unique_senders,
    count(DISTINCT channel) AS active_channels,
    pg_size_pretty(pg_total_relation_size('public.agent_chat'::regclass)) AS table_size,
    min(created_at) AS oldest_message,
    max(created_at) AS newest_message
   FROM public.agent_chat;


ALTER VIEW public.v_agent_chat_stats OWNER TO nova;

--
-- Name: v_agents; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_agents AS
 SELECT id,
    name,
    role,
    provider,
    model,
    access_method,
    persistent,
    array_to_string(skills, ', '::text) AS skills_list,
    status,
    credential_ref
   FROM public.agents
  WHERE ((status)::text = 'active'::text)
  ORDER BY persistent DESC, role, name;


ALTER VIEW public.v_agents OWNER TO nova;

--
-- Name: v_entity_facts; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_entity_facts AS
 SELECT e.id,
    e.name,
    e.type,
    ef.key,
    ef.value,
    ef.data,
    ef.learned_at
   FROM (public.entities e
     JOIN public.entity_facts ef ON ((e.id = ef.entity_id)));


ALTER VIEW public.v_entity_facts OWNER TO nova;

--
-- Name: v_event_timeline; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_event_timeline AS
 SELECT ev.event_date,
    ev.title,
    ev.description,
    array_agg(DISTINCT e.name) FILTER (WHERE (e.name IS NOT NULL)) AS entities,
    array_agg(DISTINCT p.name) FILTER (WHERE (p.name IS NOT NULL)) AS places
   FROM ((((public.events ev
     LEFT JOIN public.event_entities ee ON ((ev.id = ee.event_id)))
     LEFT JOIN public.entities e ON ((ee.entity_id = e.id)))
     LEFT JOIN public.event_places ep ON ((ev.id = ep.event_id)))
     LEFT JOIN public.places p ON ((ep.place_id = p.id)))
  GROUP BY ev.id, ev.event_date, ev.title, ev.description
  ORDER BY ev.event_date DESC;


ALTER VIEW public.v_event_timeline OWNER TO nova;

--
-- Name: v_gambling_summary; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_gambling_summary AS
 SELECT l.name AS log_name,
    l.location,
    count(e.id) AS sessions,
    sum(e.amount) AS total,
    sum(
        CASE
            WHEN (e.amount > (0)::numeric) THEN e.amount
            ELSE (0)::numeric
        END) AS total_won,
    sum(
        CASE
            WHEN (e.amount < (0)::numeric) THEN e.amount
            ELSE (0)::numeric
        END) AS total_lost
   FROM (public.gambling_logs l
     LEFT JOIN public.gambling_entries e ON ((e.log_id = l.id)))
  WHERE (l.entity_id = 2)
  GROUP BY l.id, l.name, l.location;


ALTER VIEW public.v_gambling_summary OWNER TO nova;

--
-- Name: v_media_queue_pending; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_media_queue_pending AS
 SELECT mq.id,
    mq.url,
    mq.file_path,
    mq.media_type,
    mq.title,
    mq.creator,
    mq.priority,
    mq.status,
    mq.requested_by,
    mq.requested_at,
    mq.processing_started_at,
    mq.completed_at,
    mq.result_media_id,
    mq.error_message,
    mq.metadata,
    e.name AS requested_by_name
   FROM (public.media_queue mq
     LEFT JOIN public.entities e ON ((mq.requested_by = e.id)))
  WHERE ((mq.status)::text = 'pending'::text)
  ORDER BY mq.priority, mq.requested_at;


ALTER VIEW public.v_media_queue_pending OWNER TO nova;

--
-- Name: v_media_with_tags; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_media_with_tags AS
SELECT
    NULL::integer AS id,
    NULL::character varying(50) AS media_type,
    NULL::character varying(500) AS title,
    NULL::character varying(255) AS creator,
    NULL::text AS url,
    NULL::date AS consumed_date,
    NULL::integer AS consumed_by,
    NULL::integer AS rating,
    NULL::text AS notes,
    NULL::text AS transcript,
    NULL::timestamp without time zone AS created_at,
    NULL::text AS summary,
    NULL::jsonb AS metadata,
    NULL::text AS source_file,
    NULL::character varying(20) AS status,
    NULL::integer AS ingested_by,
    NULL::timestamp without time zone AS ingested_at,
    NULL::tsvector AS search_vector,
    NULL::character varying[] AS tags;


ALTER VIEW public.v_media_with_tags OWNER TO nova;

--
-- Name: v_metamours; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_metamours AS
 SELECT DISTINCT e1.name AS person,
    e3.name AS metamour,
    e2.name AS connected_through
   FROM ((((public.entities e1
     JOIN public.entity_relationships r1 ON ((e1.id = r1.entity_a)))
     JOIN public.entities e2 ON ((r1.entity_b = e2.id)))
     JOIN public.entity_relationships r2 ON (((e2.id = r2.entity_a) OR (e2.id = r2.entity_b))))
     JOIN public.entities e3 ON (((r2.entity_a = e3.id) OR (r2.entity_b = e3.id))))
  WHERE (((e1.name)::text = 'I)ruid'::text) AND ((r1.relationship)::text = ANY ((ARRAY['partner'::character varying, 'casual'::character varying])::text[])) AND (e3.id <> e1.id) AND (e3.id <> e2.id) AND ((e3.type)::text = 'person'::text));


ALTER VIEW public.v_metamours OWNER TO nova;

--
-- Name: v_pending_tasks; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_pending_tasks AS
 SELECT t.id,
    t.title,
    t.status,
    t.priority,
    t.due_date,
    p.name AS project_name,
    t.parent_task_id,
    t.notes
   FROM (public.tasks t
     LEFT JOIN public.projects p ON ((t.project_id = p.id)))
  WHERE ((t.status)::text = ANY ((ARRAY['pending'::character varying, 'in_progress'::character varying, 'blocked'::character varying])::text[]))
  ORDER BY t.priority, t.due_date;


ALTER VIEW public.v_pending_tasks OWNER TO nova;

--
-- Name: v_portfolio_allocation; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_portfolio_allocation AS
 SELECT p.asset_class,
    count(*) AS num_positions,
    sum((p.quantity * COALESCE(pc.price, p.avg_price))) AS market_value,
    sum(p.cost_basis) AS total_cost_basis,
    (sum((p.quantity * COALESCE(pc.price, p.avg_price))) - sum(p.cost_basis)) AS unrealized_pl
   FROM (public.positions p
     LEFT JOIN public.price_cache_v2 pc ON ((((p.symbol)::text = (pc.symbol)::text) AND ((p.asset_class)::text = (pc.asset_class)::text))))
  WHERE (p.sold_at IS NULL)
  GROUP BY p.asset_class;


ALTER VIEW public.v_portfolio_allocation OWNER TO nova;

--
-- Name: v_ralph_active; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_ralph_active AS
 SELECT session_series_id,
    agent_id,
    max(iteration) AS current_iteration,
    ( SELECT r2.status
           FROM public.ralph_sessions r2
          WHERE (r2.session_series_id = r1.session_series_id)
          ORDER BY r2.iteration DESC
         LIMIT 1) AS latest_status,
    min(created_at) AS started_at,
    sum(tokens_used) AS total_tokens,
    sum(cost) AS total_cost
   FROM public.ralph_sessions r1
  GROUP BY session_series_id, agent_id
 HAVING (( SELECT r2.status
           FROM public.ralph_sessions r2
          WHERE (r2.session_series_id = r1.session_series_id)
          ORDER BY r2.iteration DESC
         LIMIT 1) = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'CONTINUE'::text]));


ALTER VIEW public.v_ralph_active OWNER TO nova;

--
-- Name: v_relationships; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_relationships AS
 SELECT e1.name AS entity_a_name,
    e1.type AS entity_a_type,
    r.relationship,
    e2.name AS entity_b_name,
    e2.type AS entity_b_type,
    r.since
   FROM ((public.entity_relationships r
     JOIN public.entities e1 ON ((r.entity_a = e1.id)))
     JOIN public.entities e2 ON ((r.entity_b = e2.id)));


ALTER VIEW public.v_relationships OWNER TO nova;

--
-- Name: v_task_tree; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_task_tree AS
 WITH RECURSIVE task_hierarchy AS (
         SELECT tasks.id,
            tasks.title,
            tasks.status,
            tasks.priority,
            tasks.parent_task_id,
            tasks.project_id,
            tasks.due_date,
            0 AS depth,
            ARRAY[tasks.id] AS path
           FROM public.tasks
          WHERE (tasks.parent_task_id IS NULL)
        UNION ALL
         SELECT t.id,
            t.title,
            t.status,
            t.priority,
            t.parent_task_id,
            t.project_id,
            t.due_date,
            (th.depth + 1),
            (th.path || t.id)
           FROM (public.tasks t
             JOIN task_hierarchy th ON ((t.parent_task_id = th.id)))
        )
 SELECT id,
    title,
    status,
    priority,
    parent_task_id,
    project_id,
    due_date,
    depth,
    path
   FROM task_hierarchy
  ORDER BY path;


ALTER VIEW public.v_task_tree OWNER TO nova;

--
-- Name: v_users; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_users AS
 SELECT e.id,
    e.name,
    e.full_name,
    e.type,
    max(
        CASE
            WHEN ((ef.key)::text = 'phone'::text) THEN ef.value
            ELSE NULL::text
        END) AS phone,
    max(
        CASE
            WHEN ((ef.key)::text = 'email'::text) THEN ef.value
            ELSE NULL::text
        END) AS email,
    max(
        CASE
            WHEN ((ef.key)::text = 'current_timezone'::text) THEN ef.value
            ELSE NULL::text
        END) AS current_timezone,
    max(
        CASE
            WHEN ((ef.key)::text = 'home_timezone'::text) THEN ef.value
            ELSE NULL::text
        END) AS home_timezone,
    max(
        CASE
            WHEN ((ef.key)::text = 'onboarded'::text) THEN ef.value
            ELSE NULL::text
        END) AS onboarded_date,
    max(
        CASE
            WHEN ((ef.key)::text = 'owner_number'::text) THEN ef.value
            ELSE NULL::text
        END) AS owner_number,
    max(
        CASE
            WHEN ((ef.key)::text = 'signal_uuid'::text) THEN ef.value
            ELSE NULL::text
        END) AS signal_uuid
   FROM (public.entities e
     JOIN public.entity_facts ef ON ((e.id = ef.entity_id)))
  WHERE (EXISTS ( SELECT 1
           FROM public.entity_facts ef2
          WHERE ((ef2.entity_id = e.id) AND ((ef2.key)::text = ANY ((ARRAY['is_user'::character varying, 'onboarded'::character varying])::text[])))))
  GROUP BY e.id, e.name, e.full_name, e.type;


ALTER VIEW public.v_users OWNER TO nova;

--
-- Name: vehicles; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.vehicles (
    id integer NOT NULL,
    owner_id integer,
    color character varying(50),
    year integer,
    make character varying(100),
    model character varying(100),
    vin character varying(17),
    license_plate_state character varying(20),
    license_plate_number character varying(20),
    nickname character varying(100),
    notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.vehicles OWNER TO nova;

--
-- Name: vehicles_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.vehicles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.vehicles_id_seq OWNER TO nova;

--
-- Name: vehicles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.vehicles_id_seq OWNED BY public.vehicles.id;


--
-- Name: vocabulary; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.vocabulary (
    id integer NOT NULL,
    word character varying(255) NOT NULL,
    category character varying(100),
    pronunciation character varying(255),
    misheard_as text[],
    added_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    vote_count integer DEFAULT 1,
    last_confirmed timestamp without time zone DEFAULT now()
);


ALTER TABLE public.vocabulary OWNER TO nova;

--
-- Name: TABLE vocabulary; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.vocabulary IS 'Custom vocabulary for speech recognition. Add names, terms, jargon as encountered.';


--
-- Name: COLUMN vocabulary.vote_count; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.vocabulary.vote_count IS 'Reinforcement count - incremented each time this word is mentioned';


--
-- Name: COLUMN vocabulary.last_confirmed; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.vocabulary.last_confirmed IS 'Timestamp of most recent confirmation';


--
-- Name: vocabulary_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.vocabulary_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.vocabulary_id_seq OWNER TO nova;

--
-- Name: vocabulary_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.vocabulary_id_seq OWNED BY public.vocabulary.id;


--
-- Name: work_tags; Type: TABLE; Schema: public; Owner: erato
--

CREATE TABLE public.work_tags (
    work_id integer NOT NULL,
    tag_id integer NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.work_tags OWNER TO erato;

--
-- Name: works; Type: TABLE; Schema: public; Owner: erato
--

CREATE TABLE public.works (
    id integer NOT NULL,
    title character varying(255) NOT NULL,
    work_type character varying(50) NOT NULL,
    content text NOT NULL,
    context_prompt text,
    word_count integer,
    character_count integer,
    language character varying(10) DEFAULT 'en'::character varying,
    status character varying(20) DEFAULT 'draft'::character varying,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    version integer DEFAULT 1,
    parent_work_id integer,
    metadata jsonb,
    CONSTRAINT positive_counts CHECK (((word_count >= 0) AND (character_count >= 0))),
    CONSTRAINT valid_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'complete'::character varying, 'published'::character varying, 'archived'::character varying])::text[]))),
    CONSTRAINT valid_work_type CHECK (((work_type)::text = ANY ((ARRAY['haiku'::character varying, 'poem'::character varying, 'prose'::character varying, 'documentation'::character varying, 'story'::character varying, 'dialogue'::character varying, 'microfiction'::character varying, 'essay'::character varying, 'other'::character varying])::text[])))
);


ALTER TABLE public.works OWNER TO erato;

--
-- Name: works_id_seq; Type: SEQUENCE; Schema: public; Owner: erato
--

CREATE SEQUENCE public.works_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.works_id_seq OWNER TO erato;

--
-- Name: works_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: erato
--

ALTER SEQUENCE public.works_id_seq OWNED BY public.works.id;


--
-- Name: agent_actions id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_actions ALTER COLUMN id SET DEFAULT nextval('public.agent_actions_id_seq'::regclass);


--
-- Name: agent_chat id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_chat ALTER COLUMN id SET DEFAULT nextval('public.agent_chat_id_seq'::regclass);


--
-- Name: agent_domains id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_domains ALTER COLUMN id SET DEFAULT nextval('public.agent_domains_id_seq'::regclass);


--
-- Name: agent_jobs id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_jobs ALTER COLUMN id SET DEFAULT nextval('public.agent_jobs_id_seq'::regclass);


--
-- Name: agent_modifications id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_modifications ALTER COLUMN id SET DEFAULT nextval('public.agent_modifications_id_seq'::regclass);


--
-- Name: agents id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agents ALTER COLUMN id SET DEFAULT nextval('public.agents_id_seq'::regclass);


--
-- Name: ai_models id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.ai_models ALTER COLUMN id SET DEFAULT nextval('public.models_id_seq'::regclass);


--
-- Name: artwork id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.artwork ALTER COLUMN id SET DEFAULT nextval('public.artwork_id_seq'::regclass);


--
-- Name: certificates id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.certificates ALTER COLUMN id SET DEFAULT nextval('public.certificates_id_seq'::regclass);


--
-- Name: conversations id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.conversations ALTER COLUMN id SET DEFAULT nextval('public.conversations_id_seq'::regclass);


--
-- Name: entities id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entities ALTER COLUMN id SET DEFAULT nextval('public.entities_id_seq'::regclass);


--
-- Name: entity_fact_conflicts id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_fact_conflicts ALTER COLUMN id SET DEFAULT nextval('public.entity_fact_conflicts_id_seq'::regclass);


--
-- Name: entity_facts id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_facts ALTER COLUMN id SET DEFAULT nextval('public.entity_facts_id_seq'::regclass);


--
-- Name: entity_relationships id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_relationships ALTER COLUMN id SET DEFAULT nextval('public.entity_relationships_id_seq'::regclass);


--
-- Name: events id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.events ALTER COLUMN id SET DEFAULT nextval('public.events_id_seq'::regclass);


--
-- Name: gambling_entries id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.gambling_entries ALTER COLUMN id SET DEFAULT nextval('public.gambling_entries_id_seq'::regclass);


--
-- Name: gambling_logs id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.gambling_logs ALTER COLUMN id SET DEFAULT nextval('public.gambling_logs_id_seq'::regclass);


--
-- Name: job_messages id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.job_messages ALTER COLUMN id SET DEFAULT nextval('public.job_messages_id_seq'::regclass);


--
-- Name: lessons id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.lessons ALTER COLUMN id SET DEFAULT nextval('public.lessons_id_seq'::regclass);


--
-- Name: media_consumed id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_consumed ALTER COLUMN id SET DEFAULT nextval('public.media_consumed_id_seq'::regclass);


--
-- Name: media_queue id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_queue ALTER COLUMN id SET DEFAULT nextval('public.media_queue_id_seq'::regclass);


--
-- Name: media_tags id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_tags ALTER COLUMN id SET DEFAULT nextval('public.media_tags_id_seq'::regclass);


--
-- Name: memory_embeddings id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.memory_embeddings ALTER COLUMN id SET DEFAULT nextval('public.memory_embeddings_id_seq'::regclass);


--
-- Name: music_analysis id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.music_analysis ALTER COLUMN id SET DEFAULT nextval('public.music_analysis_id_seq'::regclass);


--
-- Name: music_library id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.music_library ALTER COLUMN id SET DEFAULT nextval('public.music_library_id_seq'::regclass);


--
-- Name: place_properties id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.place_properties ALTER COLUMN id SET DEFAULT nextval('public.place_properties_id_seq'::regclass);


--
-- Name: places id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.places ALTER COLUMN id SET DEFAULT nextval('public.places_id_seq'::regclass);


--
-- Name: portfolio_positions id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.portfolio_positions ALTER COLUMN id SET DEFAULT nextval('public.portfolio_positions_id_seq'::regclass);


--
-- Name: portfolio_snapshots id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.portfolio_snapshots ALTER COLUMN id SET DEFAULT nextval('public.portfolio_snapshots_id_seq'::regclass);


--
-- Name: positions id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.positions ALTER COLUMN id SET DEFAULT nextval('public.positions_id_seq'::regclass);


--
-- Name: preferences id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.preferences ALTER COLUMN id SET DEFAULT nextval('public.preferences_id_seq'::regclass);


--
-- Name: project_tasks id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_tasks ALTER COLUMN id SET DEFAULT nextval('public.project_tasks_id_seq'::regclass);


--
-- Name: projects id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.projects ALTER COLUMN id SET DEFAULT nextval('public.projects_id_seq'::regclass);


--
-- Name: publications id; Type: DEFAULT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.publications ALTER COLUMN id SET DEFAULT nextval('public.publications_id_seq'::regclass);


--
-- Name: ralph_sessions id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.ralph_sessions ALTER COLUMN id SET DEFAULT nextval('public.ralph_sessions_id_seq'::regclass);


--
-- Name: sops id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sops ALTER COLUMN id SET DEFAULT nextval('public.sops_id_seq'::regclass);


--
-- Name: tags id; Type: DEFAULT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.tags ALTER COLUMN id SET DEFAULT nextval('public.tags_id_seq'::regclass);


--
-- Name: tasks id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks ALTER COLUMN id SET DEFAULT nextval('public.tasks_id_seq'::regclass);


--
-- Name: unsolved_problems id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.unsolved_problems ALTER COLUMN id SET DEFAULT nextval('public.unsolved_problems_id_seq'::regclass);


--
-- Name: vehicles id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.vehicles ALTER COLUMN id SET DEFAULT nextval('public.vehicles_id_seq'::regclass);


--
-- Name: vocabulary id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.vocabulary ALTER COLUMN id SET DEFAULT nextval('public.vocabulary_id_seq'::regclass);


--
-- Name: works id; Type: DEFAULT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.works ALTER COLUMN id SET DEFAULT nextval('public.works_id_seq'::regclass);


--
-- Name: agent_actions agent_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_actions
    ADD CONSTRAINT agent_actions_pkey PRIMARY KEY (id);


--
-- Name: agent_chat agent_chat_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_chat
    ADD CONSTRAINT agent_chat_pkey PRIMARY KEY (id);


--
-- Name: agent_chat_processed agent_chat_processed_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_chat_processed
    ADD CONSTRAINT agent_chat_processed_pkey PRIMARY KEY (chat_id, agent);


--
-- Name: agent_domains agent_domains_domain_topic_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_domains
    ADD CONSTRAINT agent_domains_domain_topic_key UNIQUE (domain_topic);


--
-- Name: agent_domains agent_domains_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_domains
    ADD CONSTRAINT agent_domains_pkey PRIMARY KEY (id);


--
-- Name: agent_jobs agent_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_jobs
    ADD CONSTRAINT agent_jobs_pkey PRIMARY KEY (id);


--
-- Name: agent_modifications agent_modifications_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_modifications
    ADD CONSTRAINT agent_modifications_pkey PRIMARY KEY (id);


--
-- Name: agent_system_config agent_system_config_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_system_config
    ADD CONSTRAINT agent_system_config_pkey PRIMARY KEY (key);


--
-- Name: agents agents_name_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_name_key UNIQUE (name);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: artwork artwork_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.artwork
    ADD CONSTRAINT artwork_pkey PRIMARY KEY (id);


--
-- Name: asset_classes asset_classes_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.asset_classes
    ADD CONSTRAINT asset_classes_pkey PRIMARY KEY (code);


--
-- Name: certificates certificates_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_fingerprint_key UNIQUE (fingerprint);


--
-- Name: certificates certificates_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_pkey PRIMARY KEY (id);


--
-- Name: certificates certificates_serial_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_serial_key UNIQUE (serial);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: entities entities_name_type_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entities
    ADD CONSTRAINT entities_name_type_key UNIQUE (name, type);


--
-- Name: entities entities_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entities
    ADD CONSTRAINT entities_pkey PRIMARY KEY (id);


--
-- Name: entities entities_user_id_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entities
    ADD CONSTRAINT entities_user_id_key UNIQUE (user_id);


--
-- Name: entity_fact_conflicts entity_fact_conflicts_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_fact_conflicts
    ADD CONSTRAINT entity_fact_conflicts_pkey PRIMARY KEY (id);


--
-- Name: entity_facts entity_facts_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_facts
    ADD CONSTRAINT entity_facts_pkey PRIMARY KEY (id);


--
-- Name: entity_relationships entity_relationships_entity_a_entity_b_relationship_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_relationships
    ADD CONSTRAINT entity_relationships_entity_a_entity_b_relationship_key UNIQUE (entity_a, entity_b, relationship);


--
-- Name: entity_relationships entity_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_relationships
    ADD CONSTRAINT entity_relationships_pkey PRIMARY KEY (id);


--
-- Name: event_entities event_entities_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_entities
    ADD CONSTRAINT event_entities_pkey PRIMARY KEY (event_id, entity_id);


--
-- Name: event_places event_places_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_places
    ADD CONSTRAINT event_places_pkey PRIMARY KEY (event_id, place_id);


--
-- Name: event_projects event_projects_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_projects
    ADD CONSTRAINT event_projects_pkey PRIMARY KEY (event_id, project_id);


--
-- Name: events_archive events_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.events_archive
    ADD CONSTRAINT events_archive_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: gambling_entries gambling_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.gambling_entries
    ADD CONSTRAINT gambling_entries_pkey PRIMARY KEY (id);


--
-- Name: gambling_logs gambling_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.gambling_logs
    ADD CONSTRAINT gambling_logs_pkey PRIMARY KEY (id);


--
-- Name: job_messages job_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.job_messages
    ADD CONSTRAINT job_messages_pkey PRIMARY KEY (id);


--
-- Name: lessons_archive lessons_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.lessons_archive
    ADD CONSTRAINT lessons_archive_pkey PRIMARY KEY (id);


--
-- Name: lessons lessons_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_pkey PRIMARY KEY (id);


--
-- Name: media_consumed media_consumed_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_consumed
    ADD CONSTRAINT media_consumed_pkey PRIMARY KEY (id);


--
-- Name: media_queue media_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_queue
    ADD CONSTRAINT media_queue_pkey PRIMARY KEY (id);


--
-- Name: media_tags media_tags_media_id_tag_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_tags
    ADD CONSTRAINT media_tags_media_id_tag_key UNIQUE (media_id, tag);


--
-- Name: media_tags media_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_tags
    ADD CONSTRAINT media_tags_pkey PRIMARY KEY (id);


--
-- Name: memory_embeddings_archive memory_embeddings_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.memory_embeddings_archive
    ADD CONSTRAINT memory_embeddings_archive_pkey PRIMARY KEY (id);


--
-- Name: memory_embeddings memory_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.memory_embeddings
    ADD CONSTRAINT memory_embeddings_pkey PRIMARY KEY (id);


--
-- Name: ai_models models_model_id_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.ai_models
    ADD CONSTRAINT models_model_id_key UNIQUE (model_id);


--
-- Name: ai_models models_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.ai_models
    ADD CONSTRAINT models_pkey PRIMARY KEY (id);


--
-- Name: music_analysis music_analysis_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.music_analysis
    ADD CONSTRAINT music_analysis_pkey PRIMARY KEY (id);


--
-- Name: music_library music_library_media_id_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.music_library
    ADD CONSTRAINT music_library_media_id_key UNIQUE (media_id);


--
-- Name: music_library music_library_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.music_library
    ADD CONSTRAINT music_library_pkey PRIMARY KEY (id);


--
-- Name: place_properties place_properties_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.place_properties
    ADD CONSTRAINT place_properties_pkey PRIMARY KEY (id);


--
-- Name: places places_name_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.places
    ADD CONSTRAINT places_name_key UNIQUE (name);


--
-- Name: places places_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.places
    ADD CONSTRAINT places_pkey PRIMARY KEY (id);


--
-- Name: portfolio_positions portfolio_positions_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.portfolio_positions
    ADD CONSTRAINT portfolio_positions_pkey PRIMARY KEY (id);


--
-- Name: portfolio_snapshots portfolio_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.portfolio_snapshots
    ADD CONSTRAINT portfolio_snapshots_pkey PRIMARY KEY (id);


--
-- Name: positions positions_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_pkey PRIMARY KEY (id);


--
-- Name: preferences preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.preferences
    ADD CONSTRAINT preferences_pkey PRIMARY KEY (id);


--
-- Name: price_cache_v2 price_cache_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.price_cache_v2
    ADD CONSTRAINT price_cache_v2_pkey PRIMARY KEY (symbol, asset_class);


--
-- Name: project_entities project_entities_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_entities
    ADD CONSTRAINT project_entities_pkey PRIMARY KEY (project_id, entity_id);


--
-- Name: project_tasks project_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_tasks
    ADD CONSTRAINT project_tasks_pkey PRIMARY KEY (id);


--
-- Name: projects projects_name_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_name_key UNIQUE (name);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: publications publications_pkey; Type: CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.publications
    ADD CONSTRAINT publications_pkey PRIMARY KEY (id);


--
-- Name: ralph_sessions ralph_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.ralph_sessions
    ADD CONSTRAINT ralph_sessions_pkey PRIMARY KEY (id);


--
-- Name: ralph_sessions ralph_sessions_session_series_id_iteration_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.ralph_sessions
    ADD CONSTRAINT ralph_sessions_session_series_id_iteration_key UNIQUE (session_series_id, iteration);


--
-- Name: sops sops_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sops
    ADD CONSTRAINT sops_pkey PRIMARY KEY (id);


--
-- Name: tags tags_name_key; Type: CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_name_key UNIQUE (name);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: unsolved_problems unsolved_problems_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.unsolved_problems
    ADD CONSTRAINT unsolved_problems_pkey PRIMARY KEY (id);


--
-- Name: vehicles vehicles_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_pkey PRIMARY KEY (id);


--
-- Name: vocabulary vocabulary_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.vocabulary
    ADD CONSTRAINT vocabulary_pkey PRIMARY KEY (id);


--
-- Name: vocabulary vocabulary_word_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.vocabulary
    ADD CONSTRAINT vocabulary_word_key UNIQUE (word);


--
-- Name: work_tags work_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.work_tags
    ADD CONSTRAINT work_tags_pkey PRIMARY KEY (work_id, tag_id);


--
-- Name: works works_pkey; Type: CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.works
    ADD CONSTRAINT works_pkey PRIMARY KEY (id);


--
-- Name: events_archive_event_date_idx; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX events_archive_event_date_idx ON public.events_archive USING btree (event_date);


--
-- Name: events_archive_search_vector_idx; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX events_archive_search_vector_idx ON public.events_archive USING gin (search_vector);


--
-- Name: idx_agent_actions_agent; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_actions_agent ON public.agent_actions USING btree (agent_id);


--
-- Name: idx_agent_actions_time; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_actions_time ON public.agent_actions USING btree (created_at DESC);


--
-- Name: idx_agent_actions_type; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_actions_type ON public.agent_actions USING btree (action_type);


--
-- Name: idx_agent_chat_channel; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_chat_channel ON public.agent_chat USING btree (channel, created_at DESC);


--
-- Name: idx_agent_chat_mentions; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_chat_mentions ON public.agent_chat USING gin (mentions);


--
-- Name: idx_agent_chat_processed_unique; Type: INDEX; Schema: public; Owner: nova
--

CREATE UNIQUE INDEX idx_agent_chat_processed_unique ON public.agent_chat_processed USING btree (chat_id, agent);


--
-- Name: idx_agent_chat_sender; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_chat_sender ON public.agent_chat USING btree (sender, created_at DESC);


--
-- Name: idx_agent_domains_agent; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_domains_agent ON public.agent_domains USING btree (agent_id);


--
-- Name: idx_agent_domains_topic; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_domains_topic ON public.agent_domains USING btree (domain_topic);


--
-- Name: idx_agent_domains_votes; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_domains_votes ON public.agent_domains USING btree (vote_count DESC);


--
-- Name: idx_agent_modifications_agent_id; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_modifications_agent_id ON public.agent_modifications USING btree (agent_id);


--
-- Name: idx_agent_modifications_modified_at; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_modifications_modified_at ON public.agent_modifications USING btree (modified_at DESC);


--
-- Name: idx_agents_provider; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agents_provider ON public.agents USING btree (provider);


--
-- Name: idx_agents_role; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agents_role ON public.agents USING btree (role);


--
-- Name: idx_agents_status; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agents_status ON public.agents USING btree (status);


--
-- Name: idx_certificates_entity_id; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_certificates_entity_id ON public.certificates USING btree (entity_id);


--
-- Name: idx_certificates_fingerprint; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_certificates_fingerprint ON public.certificates USING btree (fingerprint);


--
-- Name: idx_certificates_serial; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_certificates_serial ON public.certificates USING btree (serial);


--
-- Name: idx_chat_processed_agent; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_chat_processed_agent ON public.agent_chat_processed USING btree (agent);


--
-- Name: idx_entities_name; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entities_name ON public.entities USING btree (name);


--
-- Name: idx_entities_type; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entities_type ON public.entities USING btree (type);


--
-- Name: idx_entities_user_id; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entities_user_id ON public.entities USING btree (user_id) WHERE (user_id IS NOT NULL);


--
-- Name: idx_entity_facts_archive_date; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_archive_date ON public.entity_facts_archive USING btree (archived_at);


--
-- Name: idx_entity_facts_archive_entity; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_archive_entity ON public.entity_facts_archive USING btree (entity_id);


--
-- Name: idx_entity_facts_archive_key; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_archive_key ON public.entity_facts_archive USING btree (key);


--
-- Name: idx_entity_facts_confidence; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_confidence ON public.entity_facts USING btree (confidence) WHERE (confidence < (1.0)::double precision);


--
-- Name: idx_entity_facts_data; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_data ON public.entity_facts USING gin (data);


--
-- Name: idx_entity_facts_data_type; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_data_type ON public.entity_facts USING btree (data_type);


--
-- Name: idx_entity_facts_entity; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_entity ON public.entity_facts USING btree (entity_id);


--
-- Name: idx_entity_facts_key; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_key ON public.entity_facts USING btree (key);


--
-- Name: idx_entity_facts_privacy_scope; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_privacy_scope ON public.entity_facts USING gin (privacy_scope);


--
-- Name: idx_entity_facts_source_entity; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_source_entity ON public.entity_facts USING btree (source_entity_id);


--
-- Name: idx_entity_facts_value_trgm; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_value_trgm ON public.entity_facts USING gin (lower(value) public.gin_trgm_ops);


--
-- Name: idx_entity_facts_visibility; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_visibility ON public.entity_facts USING btree (visibility);


--
-- Name: idx_entity_facts_vote_count; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_vote_count ON public.entity_facts USING btree (vote_count DESC);


--
-- Name: idx_entity_rel_a; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_rel_a ON public.entity_relationships USING btree (entity_a);


--
-- Name: idx_entity_rel_b; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_rel_b ON public.entity_relationships USING btree (entity_b);


--
-- Name: idx_events_date; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_events_date ON public.events USING btree (event_date);


--
-- Name: idx_events_search; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_events_search ON public.events USING gin (search_vector);


--
-- Name: idx_gambling_entries_date; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_gambling_entries_date ON public.gambling_entries USING btree (session_date);


--
-- Name: idx_gambling_entries_log; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_gambling_entries_log ON public.gambling_entries USING btree (log_id);


--
-- Name: idx_gambling_logs_entity; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_gambling_logs_entity ON public.gambling_logs USING btree (entity_id);


--
-- Name: idx_job_messages; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_job_messages ON public.job_messages USING btree (job_id, added_at);


--
-- Name: idx_jobs_agent; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_jobs_agent ON public.agent_jobs USING btree (agent_name, status);


--
-- Name: idx_jobs_parent; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_jobs_parent ON public.agent_jobs USING btree (parent_job_id);


--
-- Name: idx_jobs_requester; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_jobs_requester ON public.agent_jobs USING btree (requester_agent, status);


--
-- Name: idx_jobs_root; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_jobs_root ON public.agent_jobs USING btree (root_job_id);


--
-- Name: idx_jobs_topic; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_jobs_topic ON public.agent_jobs USING btree (agent_name, topic) WHERE ((status)::text <> ALL ((ARRAY['completed'::character varying, 'cancelled'::character varying])::text[]));


--
-- Name: idx_media_consumed_by; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_media_consumed_by ON public.media_consumed USING btree (consumed_by);


--
-- Name: idx_media_queue_priority; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_media_queue_priority ON public.media_queue USING btree (priority, requested_at);


--
-- Name: idx_media_queue_status; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_media_queue_status ON public.media_queue USING btree (status);


--
-- Name: idx_media_search; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_media_search ON public.media_consumed USING gin (search_vector);


--
-- Name: idx_media_status; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_media_status ON public.media_consumed USING btree (status);


--
-- Name: idx_media_tags_media; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_media_tags_media ON public.media_tags USING btree (media_id);


--
-- Name: idx_media_tags_tag; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_media_tags_tag ON public.media_tags USING btree (tag);


--
-- Name: idx_media_type; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_media_type ON public.media_consumed USING btree (media_type);


--
-- Name: idx_memory_embeddings_source; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_memory_embeddings_source ON public.memory_embeddings USING btree (source_type);


--
-- Name: idx_memory_embeddings_vector; Type: INDEX; Schema: public; Owner: nova
--
-- NOTE: IVFFlat index commented out by default - it breaks queries with < 1000 rows
-- IVFFlat divides vectors into clusters (lists). With 100 lists and few rows, most
-- lists are empty, causing ORDER BY queries to return 0-1 results instead of correct results.
-- 
-- Uncomment this index ONLY after you have > 1000 embeddings for better performance:
-- CREATE INDEX idx_memory_embeddings_vector ON public.memory_embeddings USING ivfflat (embedding public.vector_cosine_ops) WITH (lists='100');


--
-- Name: idx_music_analysis_music; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_analysis_music ON public.music_analysis USING btree (music_id);


--
-- Name: idx_music_analysis_search; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_analysis_search ON public.music_analysis USING gin (search_vector);


--
-- Name: idx_music_analysis_type; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_analysis_type ON public.music_analysis USING btree (analysis_type);


--
-- Name: idx_music_library_album; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_library_album ON public.music_library USING btree (musicbrainz_album_id);


--
-- Name: idx_music_library_artist; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_library_artist ON public.music_library USING btree (musicbrainz_artist_id);


--
-- Name: idx_music_library_bpm; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_library_bpm ON public.music_library USING btree (bpm);


--
-- Name: idx_music_library_genre; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_library_genre ON public.music_library USING btree (genre);


--
-- Name: idx_music_library_key; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_library_key ON public.music_library USING btree (key);


--
-- Name: idx_music_library_media; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_library_media ON public.music_library USING btree (media_id);


--
-- Name: idx_music_library_mood; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_library_mood ON public.music_library USING btree (mood);


--
-- Name: idx_music_library_year; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_library_year ON public.music_library USING btree (year);


--
-- Name: idx_music_search; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_music_search ON public.music_library USING gin (search_vector);


--
-- Name: idx_place_props_place; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_place_props_place ON public.place_properties USING btree (place_id);


--
-- Name: idx_places_type; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_places_type ON public.places USING btree (type);


--
-- Name: idx_positions_account; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_positions_account ON public.positions USING btree (account_id) WHERE (sold_at IS NULL);


--
-- Name: idx_positions_asset_class; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_positions_asset_class ON public.positions USING btree (asset_class) WHERE (sold_at IS NULL);


--
-- Name: idx_positions_held; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_positions_held ON public.portfolio_positions USING btree (sold_at) WHERE (sold_at IS NULL);


--
-- Name: idx_positions_symbol; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_positions_symbol ON public.portfolio_positions USING btree (symbol);


--
-- Name: idx_preferences_entity; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_preferences_entity ON public.preferences USING btree (entity_id);


--
-- Name: idx_preferences_key; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_preferences_key ON public.preferences USING btree (key);


--
-- Name: idx_price_cache_v2_lookup; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_price_cache_v2_lookup ON public.price_cache_v2 USING btree (symbol, asset_class, cached_at DESC);


--
-- Name: idx_project_tasks_project; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_project_tasks_project ON public.project_tasks USING btree (project_id);


--
-- Name: idx_project_tasks_status; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_project_tasks_status ON public.project_tasks USING btree (status);


--
-- Name: idx_projects_status; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_projects_status ON public.projects USING btree (status);


--
-- Name: idx_publications_by; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_publications_by ON public.publications USING btree (published_by);


--
-- Name: idx_publications_date; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_publications_date ON public.publications USING btree (published_at DESC);


--
-- Name: idx_publications_type; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_publications_type ON public.publications USING btree (publication_type);


--
-- Name: idx_publications_work; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_publications_work ON public.publications USING btree (work_id);


--
-- Name: idx_ralph_series_latest; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_ralph_series_latest ON public.ralph_sessions USING btree (session_series_id, iteration DESC);


--
-- Name: idx_ralph_status; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_ralph_status ON public.ralph_sessions USING btree (status) WHERE (status = ANY (ARRAY['PENDING'::text, 'RUNNING'::text]));


--
-- Name: idx_snapshots_date; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_snapshots_date ON public.portfolio_snapshots USING btree (snapshot_at);


--
-- Name: idx_snapshots_day; Type: INDEX; Schema: public; Owner: nova
--

CREATE UNIQUE INDEX idx_snapshots_day ON public.portfolio_snapshots USING btree (((snapshot_at)::date));


--
-- Name: idx_tags_category; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_tags_category ON public.tags USING btree (category);


--
-- Name: idx_tags_name; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_tags_name ON public.tags USING btree (name);


--
-- Name: idx_tasks_due; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_tasks_due ON public.tasks USING btree (due_date);


--
-- Name: idx_tasks_parent; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_tasks_parent ON public.tasks USING btree (parent_task_id);


--
-- Name: idx_tasks_priority; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_tasks_priority ON public.tasks USING btree (priority);


--
-- Name: idx_tasks_project; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_tasks_project ON public.tasks USING btree (project_id);


--
-- Name: idx_tasks_status; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_tasks_status ON public.tasks USING btree (status);


--
-- Name: idx_unsolved_problems_priority; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_unsolved_problems_priority ON public.unsolved_problems USING btree (priority DESC);


--
-- Name: idx_unsolved_problems_status; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_unsolved_problems_status ON public.unsolved_problems USING btree (status);


--
-- Name: idx_vehicles_owner; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_vehicles_owner ON public.vehicles USING btree (owner_id);


--
-- Name: idx_vehicles_vin; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_vehicles_vin ON public.vehicles USING btree (vin);


--
-- Name: idx_vocabulary_vote_count; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_vocabulary_vote_count ON public.vocabulary USING btree (vote_count DESC);


--
-- Name: idx_work_tags_tag; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_work_tags_tag ON public.work_tags USING btree (tag_id);


--
-- Name: idx_work_tags_work; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_work_tags_work ON public.work_tags USING btree (work_id);


--
-- Name: idx_works_created; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_works_created ON public.works USING btree (created_at DESC);


--
-- Name: idx_works_language; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_works_language ON public.works USING btree (language);


--
-- Name: idx_works_metadata; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_works_metadata ON public.works USING gin (metadata);


--
-- Name: idx_works_status; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_works_status ON public.works USING btree (status);


--
-- Name: idx_works_type; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_works_type ON public.works USING btree (work_type);


--
-- Name: idx_works_updated; Type: INDEX; Schema: public; Owner: erato
--

CREATE INDEX idx_works_updated ON public.works USING btree (updated_at DESC);


--
-- Name: memory_embeddings_archive_embedding_idx; Type: INDEX; Schema: public; Owner: nova
--
-- NOTE: IVFFlat index commented out by default - it breaks queries with < 1000 rows
-- See note on idx_memory_embeddings_vector above for explanation.
-- 
-- Uncomment this index ONLY after you have > 1000 archived embeddings:
-- CREATE INDEX memory_embeddings_archive_embedding_idx ON public.memory_embeddings_archive USING ivfflat (embedding public.vector_cosine_ops) WITH (lists='100');


--
-- Name: memory_embeddings_archive_source_type_idx; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX memory_embeddings_archive_source_type_idx ON public.memory_embeddings_archive USING btree (source_type);


--
-- Name: v_media_with_tags _RETURN; Type: RULE; Schema: public; Owner: nova
--

CREATE OR REPLACE VIEW public.v_media_with_tags AS
 SELECT mc.id,
    mc.media_type,
    mc.title,
    mc.creator,
    mc.url,
    mc.consumed_date,
    mc.consumed_by,
    mc.rating,
    mc.notes,
    mc.transcript,
    mc.created_at,
    mc.summary,
    mc.metadata,
    mc.source_file,
    mc.status,
    mc.ingested_by,
    mc.ingested_at,
    mc.search_vector,
    array_agg(mt.tag) FILTER (WHERE (mt.tag IS NOT NULL)) AS tags
   FROM (public.media_consumed mc
     LEFT JOIN public.media_tags mt ON ((mc.id = mt.media_id)))
  GROUP BY mc.id;


--
-- Name: agent_chat agent_chat_notify; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER agent_chat_notify AFTER INSERT ON public.agent_chat FOR EACH ROW EXECUTE FUNCTION public.notify_agent_chat();


--
-- Name: agents agents_updated_at; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER agents_updated_at BEFORE UPDATE ON public.agents FOR EACH ROW EXECUTE FUNCTION public.update_agents_timestamp();


--
-- Name: projects enforce_project_lock; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER enforce_project_lock BEFORE UPDATE ON public.projects FOR EACH ROW EXECUTE FUNCTION public.prevent_locked_project_update();


--
-- Name: gambling_entries gambling_entries_notify; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER gambling_entries_notify AFTER INSERT OR DELETE OR UPDATE ON public.gambling_entries FOR EACH ROW EXECUTE FUNCTION public.notify_gambling_change();


--
-- Name: gambling_logs gambling_logs_notify; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER gambling_logs_notify AFTER INSERT OR DELETE OR UPDATE ON public.gambling_logs FOR EACH ROW EXECUTE FUNCTION public.notify_gambling_change();


--
-- Name: media_consumed media_search_update; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER media_search_update BEFORE INSERT OR UPDATE ON public.media_consumed FOR EACH ROW EXECUTE FUNCTION public.update_media_search_vector();


--
-- Name: media_consumed media_search_vector_update; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER media_search_vector_update BEFORE INSERT OR UPDATE ON public.media_consumed FOR EACH ROW EXECUTE FUNCTION public.update_media_search_vector();


--
-- Name: music_analysis music_analysis_search_update; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER music_analysis_search_update BEFORE INSERT OR UPDATE ON public.music_analysis FOR EACH ROW EXECUTE FUNCTION public.update_music_analysis_search_vector();


--
-- Name: music_library music_search_update; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER music_search_update BEFORE INSERT OR UPDATE ON public.music_library FOR EACH ROW EXECUTE FUNCTION public.update_music_search_vector();


--
-- Name: publications publication_status_update; Type: TRIGGER; Schema: public; Owner: erato
--

CREATE TRIGGER publication_status_update AFTER INSERT ON public.publications FOR EACH ROW EXECUTE FUNCTION public.update_work_status_on_publication();


--
-- Name: agent_chat trg_embed_chat_message; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER trg_embed_chat_message AFTER INSERT ON public.agent_chat FOR EACH ROW EXECUTE FUNCTION public.embed_chat_message();


--
-- Name: agent_chat trg_notify_agent_chat; Type: TRIGGER; Schema: public; Owner: nova
--

CREATE TRIGGER trg_notify_agent_chat AFTER INSERT ON public.agent_chat FOR EACH ROW EXECUTE FUNCTION public.notify_agent_chat();


--
-- Name: works works_calculate_counts; Type: TRIGGER; Schema: public; Owner: erato
--

CREATE TRIGGER works_calculate_counts BEFORE INSERT OR UPDATE OF content ON public.works FOR EACH ROW EXECUTE FUNCTION public.calculate_word_count();


--
-- Name: works works_updated_at; Type: TRIGGER; Schema: public; Owner: erato
--

CREATE TRIGGER works_updated_at BEFORE UPDATE ON public.works FOR EACH ROW EXECUTE FUNCTION public.update_works_timestamp();


--
-- Name: agent_actions agent_actions_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_actions
    ADD CONSTRAINT agent_actions_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.entities(id);


--
-- Name: agent_actions agent_actions_related_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_actions
    ADD CONSTRAINT agent_actions_related_event_id_fkey FOREIGN KEY (related_event_id) REFERENCES public.events(id);


--
-- Name: agent_actions agent_actions_related_media_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_actions
    ADD CONSTRAINT agent_actions_related_media_id_fkey FOREIGN KEY (related_media_id) REFERENCES public.media_consumed(id);


--
-- Name: agent_chat_processed agent_chat_processed_chat_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_chat_processed
    ADD CONSTRAINT agent_chat_processed_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.agent_chat(id);


--
-- Name: agent_chat agent_chat_reply_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_chat
    ADD CONSTRAINT agent_chat_reply_to_fkey FOREIGN KEY (reply_to) REFERENCES public.agent_chat(id);


--
-- Name: agent_domains agent_domains_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_domains
    ADD CONSTRAINT agent_domains_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: agent_domains agent_domains_source_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_domains
    ADD CONSTRAINT agent_domains_source_entity_id_fkey FOREIGN KEY (source_entity_id) REFERENCES public.entities(id);


--
-- Name: agent_jobs agent_jobs_parent_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_jobs
    ADD CONSTRAINT agent_jobs_parent_job_id_fkey FOREIGN KEY (parent_job_id) REFERENCES public.agent_jobs(id);


--
-- Name: agent_jobs agent_jobs_root_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_jobs
    ADD CONSTRAINT agent_jobs_root_job_id_fkey FOREIGN KEY (root_job_id) REFERENCES public.agent_jobs(id);


--
-- Name: certificates certificates_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: entity_fact_conflicts entity_fact_conflicts_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_fact_conflicts
    ADD CONSTRAINT entity_fact_conflicts_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: entity_facts entity_facts_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_facts
    ADD CONSTRAINT entity_facts_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(id) ON DELETE CASCADE;


--
-- Name: entity_facts entity_facts_source_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_facts
    ADD CONSTRAINT entity_facts_source_entity_id_fkey FOREIGN KEY (source_entity_id) REFERENCES public.entities(id);


--
-- Name: entity_relationships entity_relationships_entity_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_relationships
    ADD CONSTRAINT entity_relationships_entity_a_fkey FOREIGN KEY (entity_a) REFERENCES public.entities(id) ON DELETE CASCADE;


--
-- Name: entity_relationships entity_relationships_entity_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.entity_relationships
    ADD CONSTRAINT entity_relationships_entity_b_fkey FOREIGN KEY (entity_b) REFERENCES public.entities(id) ON DELETE CASCADE;


--
-- Name: event_entities event_entities_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_entities
    ADD CONSTRAINT event_entities_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(id) ON DELETE CASCADE;


--
-- Name: event_entities event_entities_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_entities
    ADD CONSTRAINT event_entities_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE;


--
-- Name: event_places event_places_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_places
    ADD CONSTRAINT event_places_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE;


--
-- Name: event_places event_places_place_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_places
    ADD CONSTRAINT event_places_place_id_fkey FOREIGN KEY (place_id) REFERENCES public.places(id) ON DELETE CASCADE;


--
-- Name: event_projects event_projects_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_projects
    ADD CONSTRAINT event_projects_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE;


--
-- Name: event_projects event_projects_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.event_projects
    ADD CONSTRAINT event_projects_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: agent_modifications fk_agent_modifications_agent; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_modifications
    ADD CONSTRAINT fk_agent_modifications_agent FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: gambling_entries gambling_entries_log_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.gambling_entries
    ADD CONSTRAINT gambling_entries_log_id_fkey FOREIGN KEY (log_id) REFERENCES public.gambling_logs(id) ON DELETE CASCADE;


--
-- Name: gambling_logs gambling_logs_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.gambling_logs
    ADD CONSTRAINT gambling_logs_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(id) ON DELETE CASCADE;


--
-- Name: job_messages job_messages_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.job_messages
    ADD CONSTRAINT job_messages_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.agent_jobs(id);


--
-- Name: job_messages job_messages_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.job_messages
    ADD CONSTRAINT job_messages_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.agent_chat(id);


--
-- Name: media_consumed media_consumed_consumed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_consumed
    ADD CONSTRAINT media_consumed_consumed_by_fkey FOREIGN KEY (consumed_by) REFERENCES public.entities(id);


--
-- Name: media_consumed media_consumed_ingested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_consumed
    ADD CONSTRAINT media_consumed_ingested_by_fkey FOREIGN KEY (ingested_by) REFERENCES public.agents(id);


--
-- Name: media_queue media_queue_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_queue
    ADD CONSTRAINT media_queue_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES public.entities(id);


--
-- Name: media_queue media_queue_result_media_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_queue
    ADD CONSTRAINT media_queue_result_media_id_fkey FOREIGN KEY (result_media_id) REFERENCES public.media_consumed(id);


--
-- Name: media_tags media_tags_media_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.media_tags
    ADD CONSTRAINT media_tags_media_id_fkey FOREIGN KEY (media_id) REFERENCES public.media_consumed(id) ON DELETE CASCADE;


--
-- Name: music_analysis music_analysis_analyzed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.music_analysis
    ADD CONSTRAINT music_analysis_analyzed_by_fkey FOREIGN KEY (analyzed_by) REFERENCES public.agents(id);


--
-- Name: music_analysis music_analysis_music_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.music_analysis
    ADD CONSTRAINT music_analysis_music_id_fkey FOREIGN KEY (music_id) REFERENCES public.music_library(id) ON DELETE CASCADE;


--
-- Name: music_library music_library_media_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.music_library
    ADD CONSTRAINT music_library_media_id_fkey FOREIGN KEY (media_id) REFERENCES public.media_consumed(id) ON DELETE CASCADE;


--
-- Name: place_properties place_properties_place_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.place_properties
    ADD CONSTRAINT place_properties_place_id_fkey FOREIGN KEY (place_id) REFERENCES public.places(id) ON DELETE CASCADE;


--
-- Name: places places_parent_place_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.places
    ADD CONSTRAINT places_parent_place_id_fkey FOREIGN KEY (parent_place_id) REFERENCES public.places(id);


--
-- Name: preferences preferences_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.preferences
    ADD CONSTRAINT preferences_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(id) ON DELETE CASCADE;


--
-- Name: project_entities project_entities_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_entities
    ADD CONSTRAINT project_entities_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(id) ON DELETE CASCADE;


--
-- Name: project_entities project_entities_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_entities
    ADD CONSTRAINT project_entities_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: project_tasks project_tasks_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_tasks
    ADD CONSTRAINT project_tasks_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: publications publications_work_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.publications
    ADD CONSTRAINT publications_work_id_fkey FOREIGN KEY (work_id) REFERENCES public.works(id) ON DELETE CASCADE;


--
-- Name: tasks tasks_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.entities(id);


--
-- Name: tasks tasks_blocked_on_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_blocked_on_fkey FOREIGN KEY (blocked_on) REFERENCES public.entities(id);


--
-- Name: tasks tasks_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.entities(id);


--
-- Name: tasks tasks_parent_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_parent_task_id_fkey FOREIGN KEY (parent_task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: tasks tasks_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


--
-- Name: vehicles vehicles_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.entities(id);


--
-- Name: work_tags work_tags_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.work_tags
    ADD CONSTRAINT work_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;


--
-- Name: work_tags work_tags_work_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.work_tags
    ADD CONSTRAINT work_tags_work_id_fkey FOREIGN KEY (work_id) REFERENCES public.works(id) ON DELETE CASCADE;


--
-- Name: works works_parent_work_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: erato
--

ALTER TABLE ONLY public.works
    ADD CONSTRAINT works_parent_work_id_fkey FOREIGN KEY (parent_work_id) REFERENCES public.works(id) ON DELETE SET NULL;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO newhart;
GRANT USAGE ON SCHEMA public TO gem;
GRANT USAGE ON SCHEMA public TO coder;
GRANT USAGE ON SCHEMA public TO scout;
GRANT USAGE ON SCHEMA public TO iris;
GRANT USAGE ON SCHEMA public TO gidget;
GRANT USAGE ON SCHEMA public TO ticker;
GRANT USAGE ON SCHEMA public TO athena;
GRANT ALL ON SCHEMA public TO erato;


--
-- Name: FUNCTION chat(p_message text, p_sender character varying); Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON FUNCTION public.chat(p_message text, p_sender character varying) TO newhart;


--
-- Name: FUNCTION send_agent_message(p_sender character varying, p_message text, p_channel character varying, p_mentions text[]); Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON FUNCTION public.send_agent_message(p_sender character varying, p_message text, p_channel character varying, p_mentions text[]) TO newhart;


--
-- Name: TABLE agent_actions; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.agent_actions TO newhart;
GRANT SELECT ON TABLE public.agent_actions TO gem;
GRANT SELECT ON TABLE public.agent_actions TO coder;
GRANT SELECT ON TABLE public.agent_actions TO scout;
GRANT SELECT ON TABLE public.agent_actions TO iris;
GRANT SELECT ON TABLE public.agent_actions TO gidget;
GRANT SELECT ON TABLE public.agent_actions TO ticker;
GRANT SELECT ON TABLE public.agent_actions TO athena;
GRANT ALL ON TABLE public.agent_actions TO "nova-staging";


--
-- Name: SEQUENCE agent_actions_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.agent_actions_id_seq TO "nova-staging";


--
-- Name: TABLE agent_chat; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,INSERT ON TABLE public.agent_chat TO newhart;
GRANT SELECT,INSERT ON TABLE public.agent_chat TO gem;
GRANT SELECT,INSERT ON TABLE public.agent_chat TO coder;
GRANT SELECT,INSERT ON TABLE public.agent_chat TO scout;
GRANT SELECT,INSERT ON TABLE public.agent_chat TO iris;
GRANT SELECT,INSERT ON TABLE public.agent_chat TO gidget;
GRANT SELECT,INSERT ON TABLE public.agent_chat TO ticker;
GRANT SELECT,INSERT ON TABLE public.agent_chat TO athena;
GRANT ALL ON TABLE public.agent_chat TO "nova-staging";


--
-- Name: SEQUENCE agent_chat_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO newhart;
GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO gem;
GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO coder;
GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO scout;
GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO iris;
GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO gidget;
GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO ticker;
GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO athena;
GRANT ALL ON SEQUENCE public.agent_chat_id_seq TO "nova-staging";


--
-- Name: TABLE agent_chat_processed; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.agent_chat_processed TO newhart;
GRANT SELECT ON TABLE public.agent_chat_processed TO gem;
GRANT SELECT ON TABLE public.agent_chat_processed TO coder;
GRANT SELECT ON TABLE public.agent_chat_processed TO scout;
GRANT SELECT ON TABLE public.agent_chat_processed TO iris;
GRANT SELECT ON TABLE public.agent_chat_processed TO gidget;
GRANT SELECT ON TABLE public.agent_chat_processed TO ticker;
GRANT SELECT ON TABLE public.agent_chat_processed TO athena;
GRANT ALL ON TABLE public.agent_chat_processed TO "nova-staging";


--
-- Name: TABLE agent_domains; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.agent_domains TO newhart;
GRANT ALL ON TABLE public.agent_domains TO "nova-staging";


--
-- Name: SEQUENCE agent_domains_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.agent_domains_id_seq TO "nova-staging";


--
-- Name: TABLE agent_jobs; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.agent_jobs TO newhart;
GRANT SELECT ON TABLE public.agent_jobs TO gem;
GRANT SELECT ON TABLE public.agent_jobs TO coder;
GRANT SELECT ON TABLE public.agent_jobs TO scout;
GRANT SELECT ON TABLE public.agent_jobs TO iris;
GRANT SELECT ON TABLE public.agent_jobs TO gidget;
GRANT SELECT ON TABLE public.agent_jobs TO ticker;
GRANT SELECT ON TABLE public.agent_jobs TO athena;
GRANT ALL ON TABLE public.agent_jobs TO "nova-staging";


--
-- Name: SEQUENCE agent_jobs_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,USAGE ON SEQUENCE public.agent_jobs_id_seq TO newhart;
GRANT ALL ON SEQUENCE public.agent_jobs_id_seq TO "nova-staging";


--
-- Name: TABLE agent_modifications; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.agent_modifications TO "nova-staging";


--
-- Name: SEQUENCE agent_modifications_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.agent_modifications_id_seq TO "nova-staging";


--
-- Name: TABLE agent_system_config; Type: ACL; Schema: public; Owner: nova
--

REVOKE ALL ON TABLE public.agent_system_config FROM nova;
GRANT SELECT ON TABLE public.agent_system_config TO nova;
GRANT SELECT ON TABLE public.agent_system_config TO PUBLIC;
GRANT INSERT,DELETE,UPDATE ON TABLE public.agent_system_config TO newhart;
GRANT ALL ON TABLE public.agent_system_config TO "nova-staging";


--
-- Name: TABLE agents; Type: ACL; Schema: public; Owner: nova
--

REVOKE ALL ON TABLE public.agents FROM nova;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,UPDATE ON TABLE public.agents TO nova;
GRANT ALL ON TABLE public.agents TO newhart;
GRANT SELECT ON TABLE public.agents TO gem;
GRANT SELECT ON TABLE public.agents TO coder;
GRANT SELECT ON TABLE public.agents TO scout;
GRANT SELECT ON TABLE public.agents TO iris;
GRANT SELECT ON TABLE public.agents TO gidget;
GRANT SELECT ON TABLE public.agents TO ticker;
GRANT SELECT ON TABLE public.agents TO athena;
GRANT ALL ON TABLE public.agents TO "nova-staging";


--
-- Name: SEQUENCE agents_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,USAGE ON SEQUENCE public.agents_id_seq TO newhart;
GRANT ALL ON SEQUENCE public.agents_id_seq TO "nova-staging";


--
-- Name: TABLE ai_models; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.ai_models TO newhart;
GRANT ALL ON TABLE public.ai_models TO "nova-staging";


--
-- Name: TABLE artwork; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.artwork TO newhart;
GRANT SELECT ON TABLE public.artwork TO gem;
GRANT SELECT ON TABLE public.artwork TO coder;
GRANT SELECT ON TABLE public.artwork TO scout;
GRANT SELECT ON TABLE public.artwork TO iris;
GRANT SELECT ON TABLE public.artwork TO gidget;
GRANT SELECT ON TABLE public.artwork TO ticker;
GRANT SELECT ON TABLE public.artwork TO athena;
GRANT ALL ON TABLE public.artwork TO "nova-staging";


--
-- Name: SEQUENCE artwork_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.artwork_id_seq TO "nova-staging";


--
-- Name: TABLE asset_classes; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.asset_classes TO newhart;
GRANT SELECT ON TABLE public.asset_classes TO gem;
GRANT SELECT ON TABLE public.asset_classes TO coder;
GRANT SELECT ON TABLE public.asset_classes TO scout;
GRANT SELECT ON TABLE public.asset_classes TO iris;
GRANT SELECT ON TABLE public.asset_classes TO gidget;
GRANT SELECT ON TABLE public.asset_classes TO ticker;
GRANT SELECT ON TABLE public.asset_classes TO athena;
GRANT ALL ON TABLE public.asset_classes TO "nova-staging";


--
-- Name: TABLE certificates; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.certificates TO newhart;
GRANT SELECT ON TABLE public.certificates TO gem;
GRANT SELECT ON TABLE public.certificates TO coder;
GRANT SELECT ON TABLE public.certificates TO scout;
GRANT SELECT ON TABLE public.certificates TO iris;
GRANT SELECT ON TABLE public.certificates TO gidget;
GRANT SELECT ON TABLE public.certificates TO ticker;
GRANT SELECT ON TABLE public.certificates TO athena;
GRANT ALL ON TABLE public.certificates TO "nova-staging";


--
-- Name: SEQUENCE certificates_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.certificates_id_seq TO "nova-staging";


--
-- Name: TABLE conversations; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.conversations TO newhart;
GRANT SELECT ON TABLE public.conversations TO gem;
GRANT SELECT ON TABLE public.conversations TO coder;
GRANT SELECT ON TABLE public.conversations TO scout;
GRANT SELECT ON TABLE public.conversations TO iris;
GRANT SELECT ON TABLE public.conversations TO gidget;
GRANT SELECT ON TABLE public.conversations TO ticker;
GRANT SELECT ON TABLE public.conversations TO athena;
GRANT ALL ON TABLE public.conversations TO "nova-staging";


--
-- Name: SEQUENCE conversations_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.conversations_id_seq TO "nova-staging";


--
-- Name: TABLE entity_facts; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.entity_facts TO newhart;
GRANT SELECT ON TABLE public.entity_facts TO gem;
GRANT SELECT ON TABLE public.entity_facts TO coder;
GRANT SELECT ON TABLE public.entity_facts TO scout;
GRANT SELECT ON TABLE public.entity_facts TO iris;
GRANT SELECT ON TABLE public.entity_facts TO gidget;
GRANT SELECT ON TABLE public.entity_facts TO ticker;
GRANT SELECT ON TABLE public.entity_facts TO athena;
GRANT ALL ON TABLE public.entity_facts TO "nova-staging";


--
-- Name: TABLE delegation_knowledge; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.delegation_knowledge TO "nova-staging";


--
-- Name: TABLE entities; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.entities TO newhart;
GRANT SELECT ON TABLE public.entities TO gem;
GRANT SELECT ON TABLE public.entities TO coder;
GRANT SELECT ON TABLE public.entities TO scout;
GRANT SELECT ON TABLE public.entities TO iris;
GRANT SELECT ON TABLE public.entities TO gidget;
GRANT SELECT ON TABLE public.entities TO ticker;
GRANT SELECT ON TABLE public.entities TO athena;
GRANT ALL ON TABLE public.entities TO "nova-staging";


--
-- Name: SEQUENCE entities_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.entities_id_seq TO "nova-staging";


--
-- Name: TABLE entity_fact_conflicts; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.entity_fact_conflicts TO "nova-staging";


--
-- Name: SEQUENCE entity_fact_conflicts_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.entity_fact_conflicts_id_seq TO "nova-staging";


--
-- Name: TABLE entity_facts_archive; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.entity_facts_archive TO "nova-staging";


--
-- Name: SEQUENCE entity_facts_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.entity_facts_id_seq TO "nova-staging";


--
-- Name: TABLE entity_relationships; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.entity_relationships TO newhart;
GRANT SELECT ON TABLE public.entity_relationships TO gem;
GRANT SELECT ON TABLE public.entity_relationships TO coder;
GRANT SELECT ON TABLE public.entity_relationships TO scout;
GRANT SELECT ON TABLE public.entity_relationships TO iris;
GRANT SELECT ON TABLE public.entity_relationships TO gidget;
GRANT SELECT ON TABLE public.entity_relationships TO ticker;
GRANT SELECT ON TABLE public.entity_relationships TO athena;
GRANT ALL ON TABLE public.entity_relationships TO "nova-staging";


--
-- Name: SEQUENCE entity_relationships_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.entity_relationships_id_seq TO "nova-staging";


--
-- Name: TABLE event_entities; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.event_entities TO newhart;
GRANT SELECT ON TABLE public.event_entities TO gem;
GRANT SELECT ON TABLE public.event_entities TO coder;
GRANT SELECT ON TABLE public.event_entities TO scout;
GRANT SELECT ON TABLE public.event_entities TO iris;
GRANT SELECT ON TABLE public.event_entities TO gidget;
GRANT SELECT ON TABLE public.event_entities TO ticker;
GRANT SELECT ON TABLE public.event_entities TO athena;
GRANT ALL ON TABLE public.event_entities TO "nova-staging";


--
-- Name: TABLE event_places; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.event_places TO newhart;
GRANT SELECT ON TABLE public.event_places TO gem;
GRANT SELECT ON TABLE public.event_places TO coder;
GRANT SELECT ON TABLE public.event_places TO scout;
GRANT SELECT ON TABLE public.event_places TO iris;
GRANT SELECT ON TABLE public.event_places TO gidget;
GRANT SELECT ON TABLE public.event_places TO ticker;
GRANT SELECT ON TABLE public.event_places TO athena;
GRANT ALL ON TABLE public.event_places TO "nova-staging";


--
-- Name: TABLE event_projects; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.event_projects TO newhart;
GRANT SELECT ON TABLE public.event_projects TO gem;
GRANT SELECT ON TABLE public.event_projects TO coder;
GRANT SELECT ON TABLE public.event_projects TO scout;
GRANT SELECT ON TABLE public.event_projects TO iris;
GRANT SELECT ON TABLE public.event_projects TO gidget;
GRANT SELECT ON TABLE public.event_projects TO ticker;
GRANT SELECT ON TABLE public.event_projects TO athena;
GRANT ALL ON TABLE public.event_projects TO "nova-staging";


--
-- Name: TABLE events; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.events TO newhart;
GRANT SELECT ON TABLE public.events TO gem;
GRANT SELECT ON TABLE public.events TO coder;
GRANT SELECT ON TABLE public.events TO scout;
GRANT SELECT ON TABLE public.events TO iris;
GRANT SELECT ON TABLE public.events TO gidget;
GRANT SELECT ON TABLE public.events TO ticker;
GRANT SELECT ON TABLE public.events TO athena;
GRANT ALL ON TABLE public.events TO "nova-staging";


--
-- Name: SEQUENCE events_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.events_id_seq TO "nova-staging";


--
-- Name: TABLE events_archive; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.events_archive TO "nova-staging";


--
-- Name: TABLE gambling_entries; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.gambling_entries TO newhart;
GRANT SELECT ON TABLE public.gambling_entries TO gem;
GRANT SELECT ON TABLE public.gambling_entries TO coder;
GRANT SELECT ON TABLE public.gambling_entries TO scout;
GRANT SELECT ON TABLE public.gambling_entries TO iris;
GRANT SELECT ON TABLE public.gambling_entries TO gidget;
GRANT SELECT ON TABLE public.gambling_entries TO ticker;
GRANT SELECT ON TABLE public.gambling_entries TO athena;
GRANT ALL ON TABLE public.gambling_entries TO "nova-staging";


--
-- Name: SEQUENCE gambling_entries_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.gambling_entries_id_seq TO "nova-staging";


--
-- Name: TABLE gambling_logs; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.gambling_logs TO newhart;
GRANT SELECT ON TABLE public.gambling_logs TO gem;
GRANT SELECT ON TABLE public.gambling_logs TO coder;
GRANT SELECT ON TABLE public.gambling_logs TO scout;
GRANT SELECT ON TABLE public.gambling_logs TO iris;
GRANT SELECT ON TABLE public.gambling_logs TO gidget;
GRANT SELECT ON TABLE public.gambling_logs TO ticker;
GRANT SELECT ON TABLE public.gambling_logs TO athena;
GRANT ALL ON TABLE public.gambling_logs TO "nova-staging";


--
-- Name: SEQUENCE gambling_logs_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.gambling_logs_id_seq TO "nova-staging";


--
-- Name: TABLE job_messages; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,INSERT ON TABLE public.job_messages TO newhart;
GRANT SELECT ON TABLE public.job_messages TO gem;
GRANT SELECT ON TABLE public.job_messages TO coder;
GRANT SELECT ON TABLE public.job_messages TO scout;
GRANT SELECT ON TABLE public.job_messages TO iris;
GRANT SELECT ON TABLE public.job_messages TO gidget;
GRANT SELECT ON TABLE public.job_messages TO ticker;
GRANT SELECT ON TABLE public.job_messages TO athena;
GRANT ALL ON TABLE public.job_messages TO "nova-staging";


--
-- Name: SEQUENCE job_messages_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,USAGE ON SEQUENCE public.job_messages_id_seq TO newhart;
GRANT ALL ON SEQUENCE public.job_messages_id_seq TO "nova-staging";


--
-- Name: TABLE lessons; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.lessons TO newhart;
GRANT SELECT ON TABLE public.lessons TO gem;
GRANT SELECT ON TABLE public.lessons TO coder;
GRANT SELECT ON TABLE public.lessons TO scout;
GRANT SELECT ON TABLE public.lessons TO iris;
GRANT SELECT ON TABLE public.lessons TO gidget;
GRANT SELECT ON TABLE public.lessons TO ticker;
GRANT SELECT ON TABLE public.lessons TO athena;
GRANT ALL ON TABLE public.lessons TO "nova-staging";


--
-- Name: SEQUENCE lessons_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.lessons_id_seq TO "nova-staging";


--
-- Name: TABLE lessons_archive; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.lessons_archive TO "nova-staging";


--
-- Name: TABLE media_consumed; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.media_consumed TO newhart;
GRANT SELECT ON TABLE public.media_consumed TO gem;
GRANT SELECT ON TABLE public.media_consumed TO coder;
GRANT SELECT ON TABLE public.media_consumed TO scout;
GRANT SELECT ON TABLE public.media_consumed TO iris;
GRANT SELECT ON TABLE public.media_consumed TO gidget;
GRANT SELECT ON TABLE public.media_consumed TO ticker;
GRANT SELECT ON TABLE public.media_consumed TO athena;
GRANT ALL ON TABLE public.media_consumed TO "nova-staging";


--
-- Name: SEQUENCE media_consumed_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.media_consumed_id_seq TO "nova-staging";


--
-- Name: TABLE media_queue; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.media_queue TO newhart;
GRANT SELECT ON TABLE public.media_queue TO gem;
GRANT SELECT ON TABLE public.media_queue TO coder;
GRANT SELECT ON TABLE public.media_queue TO scout;
GRANT SELECT ON TABLE public.media_queue TO iris;
GRANT SELECT ON TABLE public.media_queue TO gidget;
GRANT SELECT ON TABLE public.media_queue TO ticker;
GRANT SELECT ON TABLE public.media_queue TO athena;
GRANT ALL ON TABLE public.media_queue TO "nova-staging";


--
-- Name: SEQUENCE media_queue_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.media_queue_id_seq TO "nova-staging";


--
-- Name: TABLE media_tags; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.media_tags TO newhart;
GRANT SELECT ON TABLE public.media_tags TO gem;
GRANT SELECT ON TABLE public.media_tags TO coder;
GRANT SELECT ON TABLE public.media_tags TO scout;
GRANT SELECT ON TABLE public.media_tags TO iris;
GRANT SELECT ON TABLE public.media_tags TO gidget;
GRANT SELECT ON TABLE public.media_tags TO ticker;
GRANT SELECT ON TABLE public.media_tags TO athena;
GRANT ALL ON TABLE public.media_tags TO "nova-staging";


--
-- Name: SEQUENCE media_tags_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.media_tags_id_seq TO "nova-staging";


--
-- Name: TABLE memory_embeddings; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,INSERT ON TABLE public.memory_embeddings TO newhart;
GRANT SELECT,INSERT ON TABLE public.memory_embeddings TO gem;
GRANT SELECT,INSERT ON TABLE public.memory_embeddings TO coder;
GRANT SELECT,INSERT ON TABLE public.memory_embeddings TO scout;
GRANT SELECT,INSERT ON TABLE public.memory_embeddings TO iris;
GRANT SELECT,INSERT ON TABLE public.memory_embeddings TO gidget;
GRANT SELECT,INSERT ON TABLE public.memory_embeddings TO ticker;
GRANT SELECT,INSERT ON TABLE public.memory_embeddings TO athena;
GRANT ALL ON TABLE public.memory_embeddings TO "nova-staging";


--
-- Name: SEQUENCE memory_embeddings_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,USAGE ON SEQUENCE public.memory_embeddings_id_seq TO newhart;
GRANT ALL ON SEQUENCE public.memory_embeddings_id_seq TO "nova-staging";


--
-- Name: TABLE memory_embeddings_archive; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.memory_embeddings_archive TO "nova-staging";


--
-- Name: SEQUENCE models_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.models_id_seq TO "nova-staging";


--
-- Name: TABLE music_analysis; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.music_analysis TO "nova-staging";


--
-- Name: SEQUENCE music_analysis_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.music_analysis_id_seq TO "nova-staging";


--
-- Name: TABLE music_library; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.music_library TO "nova-staging";


--
-- Name: SEQUENCE music_library_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.music_library_id_seq TO "nova-staging";


--
-- Name: TABLE place_properties; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.place_properties TO newhart;
GRANT SELECT ON TABLE public.place_properties TO gem;
GRANT SELECT ON TABLE public.place_properties TO coder;
GRANT SELECT ON TABLE public.place_properties TO scout;
GRANT SELECT ON TABLE public.place_properties TO iris;
GRANT SELECT ON TABLE public.place_properties TO gidget;
GRANT SELECT ON TABLE public.place_properties TO ticker;
GRANT SELECT ON TABLE public.place_properties TO athena;
GRANT ALL ON TABLE public.place_properties TO "nova-staging";


--
-- Name: SEQUENCE place_properties_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.place_properties_id_seq TO "nova-staging";


--
-- Name: TABLE places; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.places TO newhart;
GRANT SELECT ON TABLE public.places TO gem;
GRANT SELECT ON TABLE public.places TO coder;
GRANT SELECT ON TABLE public.places TO scout;
GRANT SELECT ON TABLE public.places TO iris;
GRANT SELECT ON TABLE public.places TO gidget;
GRANT SELECT ON TABLE public.places TO ticker;
GRANT SELECT ON TABLE public.places TO athena;
GRANT ALL ON TABLE public.places TO "nova-staging";


--
-- Name: SEQUENCE places_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.places_id_seq TO "nova-staging";


--
-- Name: TABLE portfolio_positions; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.portfolio_positions TO newhart;
GRANT SELECT ON TABLE public.portfolio_positions TO gem;
GRANT SELECT ON TABLE public.portfolio_positions TO coder;
GRANT SELECT ON TABLE public.portfolio_positions TO scout;
GRANT SELECT ON TABLE public.portfolio_positions TO iris;
GRANT SELECT ON TABLE public.portfolio_positions TO gidget;
GRANT SELECT ON TABLE public.portfolio_positions TO ticker;
GRANT SELECT ON TABLE public.portfolio_positions TO athena;
GRANT ALL ON TABLE public.portfolio_positions TO "nova-staging";


--
-- Name: SEQUENCE portfolio_positions_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.portfolio_positions_id_seq TO "nova-staging";


--
-- Name: TABLE portfolio_snapshots; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.portfolio_snapshots TO newhart;
GRANT SELECT ON TABLE public.portfolio_snapshots TO gem;
GRANT SELECT ON TABLE public.portfolio_snapshots TO coder;
GRANT SELECT ON TABLE public.portfolio_snapshots TO scout;
GRANT SELECT ON TABLE public.portfolio_snapshots TO iris;
GRANT SELECT ON TABLE public.portfolio_snapshots TO gidget;
GRANT SELECT ON TABLE public.portfolio_snapshots TO ticker;
GRANT SELECT ON TABLE public.portfolio_snapshots TO athena;
GRANT ALL ON TABLE public.portfolio_snapshots TO "nova-staging";


--
-- Name: SEQUENCE portfolio_snapshots_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.portfolio_snapshots_id_seq TO "nova-staging";


--
-- Name: TABLE positions; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.positions TO newhart;
GRANT SELECT ON TABLE public.positions TO gem;
GRANT SELECT ON TABLE public.positions TO coder;
GRANT SELECT ON TABLE public.positions TO scout;
GRANT SELECT ON TABLE public.positions TO iris;
GRANT SELECT ON TABLE public.positions TO gidget;
GRANT SELECT ON TABLE public.positions TO ticker;
GRANT SELECT ON TABLE public.positions TO athena;
GRANT ALL ON TABLE public.positions TO "nova-staging";


--
-- Name: SEQUENCE positions_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.positions_id_seq TO "nova-staging";


--
-- Name: TABLE preferences; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.preferences TO newhart;
GRANT SELECT ON TABLE public.preferences TO gem;
GRANT SELECT ON TABLE public.preferences TO coder;
GRANT SELECT ON TABLE public.preferences TO scout;
GRANT SELECT ON TABLE public.preferences TO iris;
GRANT SELECT ON TABLE public.preferences TO gidget;
GRANT SELECT ON TABLE public.preferences TO ticker;
GRANT SELECT ON TABLE public.preferences TO athena;
GRANT ALL ON TABLE public.preferences TO "nova-staging";


--
-- Name: SEQUENCE preferences_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.preferences_id_seq TO "nova-staging";


--
-- Name: TABLE price_cache_v2; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.price_cache_v2 TO newhart;
GRANT SELECT ON TABLE public.price_cache_v2 TO gem;
GRANT SELECT ON TABLE public.price_cache_v2 TO coder;
GRANT SELECT ON TABLE public.price_cache_v2 TO scout;
GRANT SELECT ON TABLE public.price_cache_v2 TO iris;
GRANT SELECT ON TABLE public.price_cache_v2 TO gidget;
GRANT SELECT ON TABLE public.price_cache_v2 TO ticker;
GRANT SELECT ON TABLE public.price_cache_v2 TO athena;
GRANT ALL ON TABLE public.price_cache_v2 TO "nova-staging";


--
-- Name: TABLE project_entities; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.project_entities TO newhart;
GRANT SELECT ON TABLE public.project_entities TO gem;
GRANT SELECT ON TABLE public.project_entities TO coder;
GRANT SELECT ON TABLE public.project_entities TO scout;
GRANT SELECT ON TABLE public.project_entities TO iris;
GRANT SELECT ON TABLE public.project_entities TO gidget;
GRANT SELECT ON TABLE public.project_entities TO ticker;
GRANT SELECT ON TABLE public.project_entities TO athena;
GRANT ALL ON TABLE public.project_entities TO "nova-staging";


--
-- Name: TABLE project_tasks; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.project_tasks TO newhart;
GRANT SELECT ON TABLE public.project_tasks TO gem;
GRANT SELECT ON TABLE public.project_tasks TO coder;
GRANT SELECT ON TABLE public.project_tasks TO scout;
GRANT SELECT ON TABLE public.project_tasks TO iris;
GRANT SELECT ON TABLE public.project_tasks TO gidget;
GRANT SELECT ON TABLE public.project_tasks TO ticker;
GRANT SELECT ON TABLE public.project_tasks TO athena;
GRANT ALL ON TABLE public.project_tasks TO "nova-staging";


--
-- Name: SEQUENCE project_tasks_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.project_tasks_id_seq TO "nova-staging";


--
-- Name: TABLE projects; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.projects TO newhart;
GRANT SELECT ON TABLE public.projects TO gem;
GRANT SELECT ON TABLE public.projects TO coder;
GRANT SELECT ON TABLE public.projects TO scout;
GRANT SELECT ON TABLE public.projects TO iris;
GRANT SELECT ON TABLE public.projects TO gidget;
GRANT SELECT ON TABLE public.projects TO ticker;
GRANT SELECT ON TABLE public.projects TO athena;
GRANT ALL ON TABLE public.projects TO "nova-staging";


--
-- Name: SEQUENCE projects_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.projects_id_seq TO "nova-staging";


--
-- Name: TABLE publications; Type: ACL; Schema: public; Owner: erato
--

GRANT SELECT ON TABLE public.publications TO nova;
GRANT ALL ON TABLE public.publications TO "nova-staging";


--
-- Name: SEQUENCE publications_id_seq; Type: ACL; Schema: public; Owner: erato
--

GRANT ALL ON SEQUENCE public.publications_id_seq TO "nova-staging";


--
-- Name: TABLE ralph_sessions; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.ralph_sessions TO "nova-staging";


--
-- Name: SEQUENCE ralph_sessions_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.ralph_sessions_id_seq TO "nova-staging";


--
-- Name: TABLE sops; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.sops TO newhart;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.sops TO erato;
GRANT SELECT ON TABLE public.sops TO nova;
GRANT ALL ON TABLE public.sops TO "nova-staging";


--
-- Name: SEQUENCE sops_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.sops_id_seq TO erato;
GRANT ALL ON SEQUENCE public.sops_id_seq TO "nova-staging";


--
-- Name: TABLE tags; Type: ACL; Schema: public; Owner: erato
--

GRANT SELECT ON TABLE public.tags TO nova;
GRANT ALL ON TABLE public.tags TO "nova-staging";


--
-- Name: SEQUENCE tags_id_seq; Type: ACL; Schema: public; Owner: erato
--

GRANT ALL ON SEQUENCE public.tags_id_seq TO "nova-staging";


--
-- Name: TABLE tasks; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.tasks TO newhart;
GRANT SELECT ON TABLE public.tasks TO gem;
GRANT SELECT ON TABLE public.tasks TO coder;
GRANT SELECT ON TABLE public.tasks TO scout;
GRANT SELECT ON TABLE public.tasks TO iris;
GRANT SELECT ON TABLE public.tasks TO gidget;
GRANT SELECT ON TABLE public.tasks TO ticker;
GRANT SELECT ON TABLE public.tasks TO athena;
GRANT ALL ON TABLE public.tasks TO "nova-staging";


--
-- Name: SEQUENCE tasks_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.tasks_id_seq TO "nova-staging";


--
-- Name: TABLE unsolved_problems; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.unsolved_problems TO "nova-staging";


--
-- Name: SEQUENCE unsolved_problems_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.unsolved_problems_id_seq TO "nova-staging";


--
-- Name: TABLE v_agent_chat_recent; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_agent_chat_recent TO newhart;
GRANT SELECT ON TABLE public.v_agent_chat_recent TO gem;
GRANT SELECT ON TABLE public.v_agent_chat_recent TO coder;
GRANT SELECT ON TABLE public.v_agent_chat_recent TO scout;
GRANT SELECT ON TABLE public.v_agent_chat_recent TO iris;
GRANT SELECT ON TABLE public.v_agent_chat_recent TO gidget;
GRANT SELECT ON TABLE public.v_agent_chat_recent TO ticker;
GRANT SELECT ON TABLE public.v_agent_chat_recent TO athena;
GRANT ALL ON TABLE public.v_agent_chat_recent TO "nova-staging";


--
-- Name: TABLE v_agent_chat_stats; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_agent_chat_stats TO newhart;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO gem;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO coder;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO scout;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO iris;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO gidget;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO ticker;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO athena;
GRANT ALL ON TABLE public.v_agent_chat_stats TO "nova-staging";


--
-- Name: TABLE v_agents; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_agents TO newhart;
GRANT SELECT ON TABLE public.v_agents TO gem;
GRANT SELECT ON TABLE public.v_agents TO coder;
GRANT SELECT ON TABLE public.v_agents TO scout;
GRANT SELECT ON TABLE public.v_agents TO iris;
GRANT SELECT ON TABLE public.v_agents TO gidget;
GRANT SELECT ON TABLE public.v_agents TO ticker;
GRANT SELECT ON TABLE public.v_agents TO athena;
GRANT ALL ON TABLE public.v_agents TO "nova-staging";


--
-- Name: TABLE v_entity_facts; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_entity_facts TO newhart;
GRANT SELECT ON TABLE public.v_entity_facts TO gem;
GRANT SELECT ON TABLE public.v_entity_facts TO coder;
GRANT SELECT ON TABLE public.v_entity_facts TO scout;
GRANT SELECT ON TABLE public.v_entity_facts TO iris;
GRANT SELECT ON TABLE public.v_entity_facts TO gidget;
GRANT SELECT ON TABLE public.v_entity_facts TO ticker;
GRANT SELECT ON TABLE public.v_entity_facts TO athena;
GRANT ALL ON TABLE public.v_entity_facts TO "nova-staging";


--
-- Name: TABLE v_event_timeline; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_event_timeline TO newhart;
GRANT SELECT ON TABLE public.v_event_timeline TO gem;
GRANT SELECT ON TABLE public.v_event_timeline TO coder;
GRANT SELECT ON TABLE public.v_event_timeline TO scout;
GRANT SELECT ON TABLE public.v_event_timeline TO iris;
GRANT SELECT ON TABLE public.v_event_timeline TO gidget;
GRANT SELECT ON TABLE public.v_event_timeline TO ticker;
GRANT SELECT ON TABLE public.v_event_timeline TO athena;
GRANT ALL ON TABLE public.v_event_timeline TO "nova-staging";


--
-- Name: TABLE v_gambling_summary; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_gambling_summary TO newhart;
GRANT SELECT ON TABLE public.v_gambling_summary TO gem;
GRANT SELECT ON TABLE public.v_gambling_summary TO coder;
GRANT SELECT ON TABLE public.v_gambling_summary TO scout;
GRANT SELECT ON TABLE public.v_gambling_summary TO iris;
GRANT SELECT ON TABLE public.v_gambling_summary TO gidget;
GRANT SELECT ON TABLE public.v_gambling_summary TO ticker;
GRANT SELECT ON TABLE public.v_gambling_summary TO athena;
GRANT ALL ON TABLE public.v_gambling_summary TO "nova-staging";


--
-- Name: TABLE v_media_queue_pending; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_media_queue_pending TO newhart;
GRANT SELECT ON TABLE public.v_media_queue_pending TO gem;
GRANT SELECT ON TABLE public.v_media_queue_pending TO coder;
GRANT SELECT ON TABLE public.v_media_queue_pending TO scout;
GRANT SELECT ON TABLE public.v_media_queue_pending TO iris;
GRANT SELECT ON TABLE public.v_media_queue_pending TO gidget;
GRANT SELECT ON TABLE public.v_media_queue_pending TO ticker;
GRANT SELECT ON TABLE public.v_media_queue_pending TO athena;
GRANT ALL ON TABLE public.v_media_queue_pending TO "nova-staging";


--
-- Name: TABLE v_media_with_tags; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_media_with_tags TO newhart;
GRANT SELECT ON TABLE public.v_media_with_tags TO gem;
GRANT SELECT ON TABLE public.v_media_with_tags TO coder;
GRANT SELECT ON TABLE public.v_media_with_tags TO scout;
GRANT SELECT ON TABLE public.v_media_with_tags TO iris;
GRANT SELECT ON TABLE public.v_media_with_tags TO gidget;
GRANT SELECT ON TABLE public.v_media_with_tags TO ticker;
GRANT SELECT ON TABLE public.v_media_with_tags TO athena;
GRANT ALL ON TABLE public.v_media_with_tags TO "nova-staging";


--
-- Name: TABLE v_metamours; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_metamours TO newhart;
GRANT SELECT ON TABLE public.v_metamours TO gem;
GRANT SELECT ON TABLE public.v_metamours TO coder;
GRANT SELECT ON TABLE public.v_metamours TO scout;
GRANT SELECT ON TABLE public.v_metamours TO iris;
GRANT SELECT ON TABLE public.v_metamours TO gidget;
GRANT SELECT ON TABLE public.v_metamours TO ticker;
GRANT SELECT ON TABLE public.v_metamours TO athena;
GRANT ALL ON TABLE public.v_metamours TO "nova-staging";


--
-- Name: TABLE v_pending_tasks; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_pending_tasks TO newhart;
GRANT SELECT ON TABLE public.v_pending_tasks TO gem;
GRANT SELECT ON TABLE public.v_pending_tasks TO coder;
GRANT SELECT ON TABLE public.v_pending_tasks TO scout;
GRANT SELECT ON TABLE public.v_pending_tasks TO iris;
GRANT SELECT ON TABLE public.v_pending_tasks TO gidget;
GRANT SELECT ON TABLE public.v_pending_tasks TO ticker;
GRANT SELECT ON TABLE public.v_pending_tasks TO athena;
GRANT ALL ON TABLE public.v_pending_tasks TO "nova-staging";


--
-- Name: TABLE v_portfolio_allocation; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_portfolio_allocation TO newhart;
GRANT SELECT ON TABLE public.v_portfolio_allocation TO gem;
GRANT SELECT ON TABLE public.v_portfolio_allocation TO coder;
GRANT SELECT ON TABLE public.v_portfolio_allocation TO scout;
GRANT SELECT ON TABLE public.v_portfolio_allocation TO iris;
GRANT SELECT ON TABLE public.v_portfolio_allocation TO gidget;
GRANT SELECT ON TABLE public.v_portfolio_allocation TO ticker;
GRANT SELECT ON TABLE public.v_portfolio_allocation TO athena;
GRANT ALL ON TABLE public.v_portfolio_allocation TO "nova-staging";


--
-- Name: TABLE v_ralph_active; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON TABLE public.v_ralph_active TO "nova-staging";


--
-- Name: TABLE v_relationships; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_relationships TO newhart;
GRANT SELECT ON TABLE public.v_relationships TO gem;
GRANT SELECT ON TABLE public.v_relationships TO coder;
GRANT SELECT ON TABLE public.v_relationships TO scout;
GRANT SELECT ON TABLE public.v_relationships TO iris;
GRANT SELECT ON TABLE public.v_relationships TO gidget;
GRANT SELECT ON TABLE public.v_relationships TO ticker;
GRANT SELECT ON TABLE public.v_relationships TO athena;
GRANT ALL ON TABLE public.v_relationships TO "nova-staging";


--
-- Name: TABLE v_task_tree; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_task_tree TO newhart;
GRANT SELECT ON TABLE public.v_task_tree TO gem;
GRANT SELECT ON TABLE public.v_task_tree TO coder;
GRANT SELECT ON TABLE public.v_task_tree TO scout;
GRANT SELECT ON TABLE public.v_task_tree TO iris;
GRANT SELECT ON TABLE public.v_task_tree TO gidget;
GRANT SELECT ON TABLE public.v_task_tree TO ticker;
GRANT SELECT ON TABLE public.v_task_tree TO athena;
GRANT ALL ON TABLE public.v_task_tree TO "nova-staging";


--
-- Name: TABLE v_users; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_users TO newhart;
GRANT SELECT ON TABLE public.v_users TO gem;
GRANT SELECT ON TABLE public.v_users TO coder;
GRANT SELECT ON TABLE public.v_users TO scout;
GRANT SELECT ON TABLE public.v_users TO iris;
GRANT SELECT ON TABLE public.v_users TO gidget;
GRANT SELECT ON TABLE public.v_users TO ticker;
GRANT SELECT ON TABLE public.v_users TO athena;
GRANT ALL ON TABLE public.v_users TO "nova-staging";


--
-- Name: TABLE vehicles; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.vehicles TO newhart;
GRANT SELECT ON TABLE public.vehicles TO gem;
GRANT SELECT ON TABLE public.vehicles TO coder;
GRANT SELECT ON TABLE public.vehicles TO scout;
GRANT SELECT ON TABLE public.vehicles TO iris;
GRANT SELECT ON TABLE public.vehicles TO gidget;
GRANT SELECT ON TABLE public.vehicles TO ticker;
GRANT SELECT ON TABLE public.vehicles TO athena;
GRANT ALL ON TABLE public.vehicles TO "nova-staging";


--
-- Name: SEQUENCE vehicles_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.vehicles_id_seq TO "nova-staging";


--
-- Name: TABLE vocabulary; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.vocabulary TO newhart;
GRANT SELECT ON TABLE public.vocabulary TO gem;
GRANT SELECT ON TABLE public.vocabulary TO coder;
GRANT SELECT ON TABLE public.vocabulary TO scout;
GRANT SELECT ON TABLE public.vocabulary TO iris;
GRANT SELECT ON TABLE public.vocabulary TO gidget;
GRANT SELECT ON TABLE public.vocabulary TO ticker;
GRANT SELECT ON TABLE public.vocabulary TO athena;
GRANT ALL ON TABLE public.vocabulary TO "nova-staging";


--
-- Name: SEQUENCE vocabulary_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON SEQUENCE public.vocabulary_id_seq TO "nova-staging";


--
-- Name: TABLE work_tags; Type: ACL; Schema: public; Owner: erato
--

GRANT SELECT ON TABLE public.work_tags TO nova;
GRANT ALL ON TABLE public.work_tags TO "nova-staging";


--
-- Name: TABLE works; Type: ACL; Schema: public; Owner: erato
--

GRANT SELECT ON TABLE public.works TO nova;
GRANT ALL ON TABLE public.works TO "nova-staging";


--
-- Name: SEQUENCE works_id_seq; Type: ACL; Schema: public; Owner: erato
--

GRANT ALL ON SEQUENCE public.works_id_seq TO "nova-staging";


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO erato;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT ON TABLES TO newhart;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO erato;


--
-- Name: schema_change_trigger; Type: EVENT TRIGGER; Schema: -; Owner: postgres
--

CREATE EVENT TRIGGER schema_change_trigger ON ddl_command_end
   EXECUTE FUNCTION public.notify_schema_change();


ALTER EVENT TRIGGER schema_change_trigger OWNER TO postgres;

--
-- PostgreSQL database dump complete
--

\unrestrict DL5BLliozNxgkw9q3q3NmXKHaV8PZDdFDDq54ClC3zolTBTJDCsFSN7gzFJ5cdR

