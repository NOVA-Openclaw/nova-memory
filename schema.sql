--
-- PostgreSQL database dump
--

\restrict e8aLo7cECzSdczKLvzlfgmQwuPP86eiNXgLLnmnFzxsPGKBAmNVbW4rMseZcMCW

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
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


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

COMMENT ON TABLE public.agent_actions IS 'Log of NOVA actions for continuity and avoiding duplicate work';


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
    fallback_model character varying(100)
);


ALTER TABLE public.agents OWNER TO nova;

--
-- Name: TABLE agents; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.agents IS 'Registry of persistent AI agent instances for delegation';


--
-- Name: COLUMN agents.access_details; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.access_details IS 'JSON: session_key, cli_command, endpoint URL, etc.';


--
-- Name: COLUMN agents.credential_ref; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.agents.credential_ref IS '1Password item name or clawdbot config path for credentials';


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
    nostr_image_url text
);


ALTER TABLE public.artwork OWNER TO nova;

--
-- Name: TABLE artwork; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.artwork IS 'Archive of NOVA''s Instagram artwork for future compilation';


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

COMMENT ON TABLE public.certificates IS 'Client certificates issued by NOVA CA for mTLS authentication';


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
    CONSTRAINT entities_type_check CHECK (((type)::text = ANY ((ARRAY['person'::character varying, 'ai'::character varying, 'organization'::character varying, 'pet'::character varying, 'stuffed_animal'::character varying, 'character'::character varying, 'other'::character varying])::text[])))
);


ALTER TABLE public.entities OWNER TO nova;

--
-- Name: TABLE entities; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.entities IS 'People, AIs, organizations, and other entities';


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
    visibility_reason text
);


ALTER TABLE public.entity_facts OWNER TO nova;

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
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, (((COALESCE(title, ''::character varying))::text || ' '::text) || COALESCE(description, ''::text)))) STORED
);


ALTER TABLE public.events OWNER TO nova;

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
    last_referenced timestamp without time zone
);


ALTER TABLE public.lessons OWNER TO nova;

--
-- Name: TABLE lessons; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.lessons IS 'Lessons and insights learned by NOVA';


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

COMMENT ON TABLE public.media_consumed IS 'Books, movies, podcasts, articles consumed by entities';


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

COMMENT ON TABLE public.media_queue IS 'Queue for media ingestion requests awaiting processing by Librarian Agent';


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

COMMENT ON TABLE public.media_tags IS 'Tags/topics associated with media items';


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
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.memory_embeddings OWNER TO nova;

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
-- Name: sops; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.sops (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    steps jsonb,
    tools text[],
    notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.sops OWNER TO nova;

--
-- Name: processes_id_seq; Type: SEQUENCE; Schema: public; Owner: nova
--

CREATE SEQUENCE public.processes_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.processes_id_seq OWNER TO nova;

--
-- Name: processes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: nova
--

ALTER SEQUENCE public.processes_id_seq OWNED BY public.sops.id;


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
-- Name: project_sops; Type: TABLE; Schema: public; Owner: nova
--

CREATE TABLE public.project_sops (
    project_id integer NOT NULL,
    sop_id integer NOT NULL
);


ALTER TABLE public.project_sops OWNER TO nova;

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
    CONSTRAINT projects_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'blocked'::character varying, 'complete'::character varying, 'paused'::character varying, 'abandoned'::character varying])::text[])))
);


ALTER TABLE public.projects OWNER TO nova;

--
-- Name: COLUMN projects.git_config; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.projects.git_config IS 'Per-project Git config: branch strategy, commit conventions, PR workflow, etc.';


--
-- Name: COLUMN projects.repo_url; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.projects.repo_url IS 'Canonical repo URL. When locked, this is the permanent pointer - track details in the repo itself.';


--
-- Name: COLUMN projects.locked; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON COLUMN public.projects.locked IS 'When TRUE, prevents accidental updates. Must explicitly set locked=FALSE first.';


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
    task_number integer
);


ALTER TABLE public.tasks OWNER TO nova;

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
-- Name: v_project_sops; Type: VIEW; Schema: public; Owner: nova
--

CREATE VIEW public.v_project_sops AS
 SELECT p.name AS project,
    s.name AS sop,
    s.description
   FROM ((public.project_sops ps
     JOIN public.projects p ON ((ps.project_id = p.id)))
     JOIN public.sops s ON ((ps.sop_id = s.id)));


ALTER VIEW public.v_project_sops OWNER TO nova;

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
    added_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.vocabulary OWNER TO nova;

--
-- Name: TABLE vocabulary; Type: COMMENT; Schema: public; Owner: nova
--

COMMENT ON TABLE public.vocabulary IS 'Custom vocabulary for speech recognition';


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
-- Name: agent_actions id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_actions ALTER COLUMN id SET DEFAULT nextval('public.agent_actions_id_seq'::regclass);


--
-- Name: agent_chat id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_chat ALTER COLUMN id SET DEFAULT nextval('public.agent_chat_id_seq'::regclass);


--
-- Name: agents id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agents ALTER COLUMN id SET DEFAULT nextval('public.agents_id_seq'::regclass);


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
-- Name: sops id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.sops ALTER COLUMN id SET DEFAULT nextval('public.processes_id_seq'::regclass);


--
-- Name: tasks id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks ALTER COLUMN id SET DEFAULT nextval('public.tasks_id_seq'::regclass);


--
-- Name: vehicles id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.vehicles ALTER COLUMN id SET DEFAULT nextval('public.vehicles_id_seq'::regclass);


--
-- Name: vocabulary id; Type: DEFAULT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.vocabulary ALTER COLUMN id SET DEFAULT nextval('public.vocabulary_id_seq'::regclass);


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
-- Name: memory_embeddings memory_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.memory_embeddings
    ADD CONSTRAINT memory_embeddings_pkey PRIMARY KEY (id);


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
-- Name: sops processes_name_key; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.sops
    ADD CONSTRAINT processes_name_key UNIQUE (name);


--
-- Name: sops processes_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.sops
    ADD CONSTRAINT processes_pkey PRIMARY KEY (id);


--
-- Name: project_entities project_entities_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_entities
    ADD CONSTRAINT project_entities_pkey PRIMARY KEY (project_id, entity_id);


--
-- Name: project_sops project_sops_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_sops
    ADD CONSTRAINT project_sops_pkey PRIMARY KEY (project_id, sop_id);


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
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


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
-- Name: idx_agent_chat_sender; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_agent_chat_sender ON public.agent_chat USING btree (sender, created_at DESC);


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
-- Name: idx_entity_facts_data; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_data ON public.entity_facts USING gin (data);


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
-- Name: idx_entity_facts_visibility; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_entity_facts_visibility ON public.entity_facts USING btree (visibility);


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

CREATE INDEX idx_memory_embeddings_vector ON public.memory_embeddings USING ivfflat (embedding public.vector_cosine_ops) WITH (lists='100');


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
-- Name: idx_snapshots_date; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_snapshots_date ON public.portfolio_snapshots USING btree (snapshot_at);


--
-- Name: idx_snapshots_day; Type: INDEX; Schema: public; Owner: nova
--

CREATE UNIQUE INDEX idx_snapshots_day ON public.portfolio_snapshots USING btree (((snapshot_at)::date));


--
-- Name: idx_sops_name; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_sops_name ON public.sops USING btree (name);


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
-- Name: idx_vehicles_owner; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_vehicles_owner ON public.vehicles USING btree (owner_id);


--
-- Name: idx_vehicles_vin; Type: INDEX; Schema: public; Owner: nova
--

CREATE INDEX idx_vehicles_vin ON public.vehicles USING btree (vin);


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
-- Name: agent_chat agent_chat_reply_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.agent_chat
    ADD CONSTRAINT agent_chat_reply_to_fkey FOREIGN KEY (reply_to) REFERENCES public.agent_chat(id);


--
-- Name: certificates certificates_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(id);


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
-- Name: project_sops project_sops_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_sops
    ADD CONSTRAINT project_sops_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: project_sops project_sops_sop_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_sops
    ADD CONSTRAINT project_sops_sop_id_fkey FOREIGN KEY (sop_id) REFERENCES public.sops(id) ON DELETE CASCADE;


--
-- Name: project_tasks project_tasks_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.project_tasks
    ADD CONSTRAINT project_tasks_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: tasks tasks_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nova
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.entities(id);


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
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO newhart;


--
-- Name: FUNCTION send_agent_message(p_sender character varying, p_message text, p_channel character varying, p_mentions text[]); Type: ACL; Schema: public; Owner: nova
--

GRANT ALL ON FUNCTION public.send_agent_message(p_sender character varying, p_message text, p_channel character varying, p_mentions text[]) TO newhart;


--
-- Name: TABLE agent_actions; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.agent_actions TO newhart;


--
-- Name: TABLE agent_chat; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,INSERT ON TABLE public.agent_chat TO newhart;


--
-- Name: SEQUENCE agent_chat_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,USAGE ON SEQUENCE public.agent_chat_id_seq TO newhart;


--
-- Name: TABLE agents; Type: ACL; Schema: public; Owner: nova
--

REVOKE ALL ON TABLE public.agents FROM nova;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE public.agents TO nova;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.agents TO newhart;


--
-- Name: SEQUENCE agents_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,USAGE ON SEQUENCE public.agents_id_seq TO newhart;


--
-- Name: TABLE artwork; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.artwork TO newhart;


--
-- Name: TABLE asset_classes; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.asset_classes TO newhart;


--
-- Name: TABLE certificates; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.certificates TO newhart;


--
-- Name: TABLE conversations; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.conversations TO newhart;


--
-- Name: TABLE entities; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.entities TO newhart;


--
-- Name: TABLE entity_facts; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.entity_facts TO newhart;


--
-- Name: TABLE entity_relationships; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.entity_relationships TO newhart;


--
-- Name: TABLE event_entities; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.event_entities TO newhart;


--
-- Name: TABLE event_places; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.event_places TO newhart;


--
-- Name: TABLE event_projects; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.event_projects TO newhart;


--
-- Name: TABLE events; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.events TO newhart;


--
-- Name: TABLE gambling_entries; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.gambling_entries TO newhart;


--
-- Name: TABLE gambling_logs; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.gambling_logs TO newhart;


--
-- Name: TABLE lessons; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.lessons TO newhart;


--
-- Name: TABLE media_consumed; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.media_consumed TO newhart;


--
-- Name: TABLE media_queue; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.media_queue TO newhart;


--
-- Name: TABLE media_tags; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.media_tags TO newhart;


--
-- Name: TABLE memory_embeddings; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.memory_embeddings TO newhart;


--
-- Name: TABLE place_properties; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.place_properties TO newhart;


--
-- Name: TABLE places; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.places TO newhart;


--
-- Name: TABLE portfolio_positions; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.portfolio_positions TO newhart;


--
-- Name: TABLE portfolio_snapshots; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.portfolio_snapshots TO newhart;


--
-- Name: TABLE positions; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.positions TO newhart;


--
-- Name: TABLE preferences; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.preferences TO newhart;


--
-- Name: TABLE price_cache_v2; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.price_cache_v2 TO newhart;


--
-- Name: TABLE sops; Type: ACL; Schema: public; Owner: nova
--

REVOKE ALL ON TABLE public.sops FROM nova;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE public.sops TO nova;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.sops TO newhart;


--
-- Name: SEQUENCE processes_id_seq; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT,USAGE ON SEQUENCE public.processes_id_seq TO newhart;


--
-- Name: TABLE project_entities; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.project_entities TO newhart;


--
-- Name: TABLE project_sops; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.project_sops TO newhart;


--
-- Name: TABLE project_tasks; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.project_tasks TO newhart;


--
-- Name: TABLE projects; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.projects TO newhart;


--
-- Name: TABLE tasks; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.tasks TO newhart;


--
-- Name: TABLE v_agent_chat_recent; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_agent_chat_recent TO newhart;


--
-- Name: TABLE v_agent_chat_stats; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_agent_chat_stats TO newhart;


--
-- Name: TABLE v_agents; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_agents TO newhart;


--
-- Name: TABLE v_entity_facts; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_entity_facts TO newhart;


--
-- Name: TABLE v_event_timeline; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_event_timeline TO newhart;


--
-- Name: TABLE v_gambling_summary; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_gambling_summary TO newhart;


--
-- Name: TABLE v_media_queue_pending; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_media_queue_pending TO newhart;


--
-- Name: TABLE v_media_with_tags; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_media_with_tags TO newhart;


--
-- Name: TABLE v_metamours; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_metamours TO newhart;


--
-- Name: TABLE v_pending_tasks; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_pending_tasks TO newhart;


--
-- Name: TABLE v_portfolio_allocation; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_portfolio_allocation TO newhart;


--
-- Name: TABLE v_project_sops; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_project_sops TO newhart;


--
-- Name: TABLE v_relationships; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_relationships TO newhart;


--
-- Name: TABLE v_task_tree; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_task_tree TO newhart;


--
-- Name: TABLE v_users; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.v_users TO newhart;


--
-- Name: TABLE vehicles; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.vehicles TO newhart;


--
-- Name: TABLE vocabulary; Type: ACL; Schema: public; Owner: nova
--

GRANT SELECT ON TABLE public.vocabulary TO newhart;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT ON TABLES TO newhart;


--
-- Name: schema_change_trigger; Type: EVENT TRIGGER; Schema: -; Owner: postgres
--

CREATE EVENT TRIGGER schema_change_trigger ON ddl_command_end
   EXECUTE FUNCTION public.notify_schema_change();


ALTER EVENT TRIGGER schema_change_trigger OWNER TO postgres;

--
-- PostgreSQL database dump complete
--

\unrestrict e8aLo7cECzSdczKLvzlfgmQwuPP86eiNXgLLnmnFzxsPGKBAmNVbW4rMseZcMCW

