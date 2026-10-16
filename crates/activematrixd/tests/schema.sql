--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: active_matrix_agent_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_agent_messages (
    id uuid DEFAULT uuidv7() NOT NULL,
    from_agent_id uuid,
    to_agent_id uuid NOT NULL,
    topic character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    processed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone DEFAULT now() NOT NULL
);


--
-- Name: active_matrix_agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_agents (
    id uuid DEFAULT uuidv7() NOT NULL,
    name character varying NOT NULL,
    homeserver_url character varying NOT NULL,
    bot_class character varying NOT NULL,
    state character varying DEFAULT 'offline'::character varying NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    sync_token character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id character varying,
    device_id character varying,
    access_token_ciphertext bytea,
    enabled boolean DEFAULT true NOT NULL,
    last_error text,
    last_error_at timestamp(6) without time zone,
    heartbeat_at timestamp(6) without time zone,
    claimed_by character varying,
    lease_expires_at timestamp(6) without time zone,
    CONSTRAINT active_matrix_agents_state CHECK (((state)::text = ANY (ARRAY[('offline'::character varying)::text, ('starting'::character varying)::text, ('online'::character varying)::text, ('reconnecting'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: active_matrix_chat_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_chat_sessions (
    id uuid DEFAULT uuidv7() NOT NULL,
    agent_id uuid NOT NULL,
    user_id character varying NOT NULL,
    room_id character varying NOT NULL,
    last_message_at timestamp(6) without time zone,
    message_count integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_matrix_inbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_inbox (
    id bigint NOT NULL,
    agent_id uuid NOT NULL,
    room_id character varying NOT NULL,
    event_id character varying NOT NULL,
    kind character varying DEFAULT 'timeline'::character varying NOT NULL,
    event_type character varying NOT NULL,
    sender character varying NOT NULL,
    state_key character varying,
    content jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    origin_server_ts bigint,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text,
    processed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone DEFAULT now() NOT NULL,
    CONSTRAINT active_matrix_inbox_kind CHECK (((kind)::text = ANY (ARRAY[('timeline'::character varying)::text, ('invite'::character varying)::text])))
);


--
-- Name: active_matrix_inbox_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_matrix_inbox_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_matrix_inbox_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_matrix_inbox_id_seq OWNED BY public.active_matrix_inbox.id;


--
-- Name: active_matrix_memories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_memories (
    id uuid DEFAULT uuidv7() NOT NULL,
    agent_id uuid,
    chat_session_id uuid,
    key character varying NOT NULL,
    value jsonb NOT NULL,
    expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_matrix_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_outbox (
    id uuid DEFAULT uuidv7() NOT NULL,
    agent_id uuid NOT NULL,
    kind character varying NOT NULL,
    room_id character varying,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    blob bytea,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    result jsonb,
    last_error text,
    sent_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT active_matrix_outbox_kind CHECK (((kind)::text = ANY (ARRAY[('send'::character varying)::text, ('state'::character varying)::text, ('redact'::character varying)::text, ('join'::character varying)::text, ('leave'::character varying)::text, ('invite'::character varying)::text, ('kick'::character varying)::text, ('ban'::character varying)::text, ('unban'::character varying)::text, ('create_room'::character varying)::text, ('typing'::character varying)::text, ('receipt'::character varying)::text, ('profile'::character varying)::text, ('upload'::character varying)::text]))),
    CONSTRAINT active_matrix_outbox_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('sending'::character varying)::text, ('sent'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: active_matrix_room_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_room_members (
    id uuid DEFAULT uuidv7() NOT NULL,
    agent_id uuid NOT NULL,
    room_id character varying NOT NULL,
    user_id character varying NOT NULL,
    membership character varying NOT NULL,
    display_name character varying,
    avatar_url character varying,
    created_at timestamp(6) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(6) without time zone DEFAULT now() NOT NULL
);


--
-- Name: active_matrix_room_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_room_state (
    id uuid DEFAULT uuidv7() NOT NULL,
    agent_id uuid NOT NULL,
    room_id character varying NOT NULL,
    event_type character varying NOT NULL,
    state_key character varying DEFAULT ''::character varying NOT NULL,
    event_id character varying,
    sender character varying,
    content jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(6) without time zone DEFAULT now() NOT NULL
);


--
-- Name: active_matrix_rooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_matrix_rooms (
    id uuid DEFAULT uuidv7() NOT NULL,
    agent_id uuid NOT NULL,
    room_id character varying NOT NULL,
    membership character varying NOT NULL,
    name character varying,
    topic character varying,
    canonical_alias character varying,
    avatar_url character varying,
    room_type character varying,
    encrypted boolean DEFAULT false NOT NULL,
    direct boolean DEFAULT false NOT NULL,
    joined_member_count integer DEFAULT 0 NOT NULL,
    invited_member_count integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(6) without time zone DEFAULT now() NOT NULL
);


--
-- Name: active_matrix_inbox id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_inbox ALTER COLUMN id SET DEFAULT nextval('public.active_matrix_inbox_id_seq'::regclass);


--
-- Name: active_matrix_agent_messages active_matrix_agent_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_agent_messages
    ADD CONSTRAINT active_matrix_agent_messages_pkey PRIMARY KEY (id);


--
-- Name: active_matrix_agents active_matrix_agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_agents
    ADD CONSTRAINT active_matrix_agents_pkey PRIMARY KEY (id);


--
-- Name: active_matrix_chat_sessions active_matrix_chat_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_chat_sessions
    ADD CONSTRAINT active_matrix_chat_sessions_pkey PRIMARY KEY (id);


--
-- Name: active_matrix_inbox active_matrix_inbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_inbox
    ADD CONSTRAINT active_matrix_inbox_pkey PRIMARY KEY (id);


--
-- Name: active_matrix_memories active_matrix_memories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_memories
    ADD CONSTRAINT active_matrix_memories_pkey PRIMARY KEY (id);


--
-- Name: active_matrix_outbox active_matrix_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_outbox
    ADD CONSTRAINT active_matrix_outbox_pkey PRIMARY KEY (id);


--
-- Name: active_matrix_room_members active_matrix_room_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_room_members
    ADD CONSTRAINT active_matrix_room_members_pkey PRIMARY KEY (id);


--
-- Name: active_matrix_room_state active_matrix_room_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_room_state
    ADD CONSTRAINT active_matrix_room_state_pkey PRIMARY KEY (id);


--
-- Name: active_matrix_rooms active_matrix_rooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_rooms
    ADD CONSTRAINT active_matrix_rooms_pkey PRIMARY KEY (id);


--
-- Name: index_active_matrix_agent_messages_on_from_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_agent_messages_on_from_agent_id ON public.active_matrix_agent_messages USING btree (from_agent_id);


--
-- Name: index_active_matrix_agent_messages_on_to_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_agent_messages_on_to_agent_id ON public.active_matrix_agent_messages USING btree (to_agent_id);


--
-- Name: index_active_matrix_agents_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_matrix_agents_on_name ON public.active_matrix_agents USING btree (name);


--
-- Name: index_active_matrix_agents_on_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_agents_on_state ON public.active_matrix_agents USING btree (state);


--
-- Name: index_active_matrix_chat_sessions_on_last_message_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_chat_sessions_on_last_message_at ON public.active_matrix_chat_sessions USING btree (last_message_at);


--
-- Name: index_active_matrix_inbox_on_agent_id_and_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_matrix_inbox_on_agent_id_and_event_id ON public.active_matrix_inbox USING btree (agent_id, event_id);


--
-- Name: index_active_matrix_inbox_on_processed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_inbox_on_processed_at ON public.active_matrix_inbox USING btree (processed_at) WHERE (processed_at IS NOT NULL);


--
-- Name: index_active_matrix_inbox_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_inbox_pending ON public.active_matrix_inbox USING btree (agent_id, room_id, id) WHERE (processed_at IS NULL);


--
-- Name: index_active_matrix_memories_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_matrix_memories_key ON public.active_matrix_memories USING btree (agent_id, chat_session_id, key) NULLS NOT DISTINCT;


--
-- Name: index_active_matrix_memories_on_chat_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_memories_on_chat_session_id ON public.active_matrix_memories USING btree (chat_session_id) WHERE (chat_session_id IS NOT NULL);


--
-- Name: index_active_matrix_memories_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_memories_on_expires_at ON public.active_matrix_memories USING btree (expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: index_active_matrix_outbox_on_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_outbox_on_sent_at ON public.active_matrix_outbox USING btree (sent_at) WHERE (sent_at IS NOT NULL);


--
-- Name: index_active_matrix_outbox_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_matrix_outbox_pending ON public.active_matrix_outbox USING btree (agent_id, created_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_active_matrix_room_members_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_matrix_room_members_key ON public.active_matrix_room_members USING btree (agent_id, room_id, user_id);


--
-- Name: index_active_matrix_room_state_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_matrix_room_state_key ON public.active_matrix_room_state USING btree (agent_id, room_id, event_type, state_key);


--
-- Name: index_active_matrix_rooms_on_agent_id_and_room_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_matrix_rooms_on_agent_id_and_room_id ON public.active_matrix_rooms USING btree (agent_id, room_id);


--
-- Name: index_chat_sessions_on_agent_user_room; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_chat_sessions_on_agent_user_room ON public.active_matrix_chat_sessions USING btree (agent_id, user_id, room_id);


--
-- Name: active_matrix_inbox fk_rails_5335fae2bb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_inbox
    ADD CONSTRAINT fk_rails_5335fae2bb FOREIGN KEY (agent_id) REFERENCES public.active_matrix_agents(id) ON DELETE CASCADE;


--
-- Name: active_matrix_chat_sessions fk_rails_53457da357; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_chat_sessions
    ADD CONSTRAINT fk_rails_53457da357 FOREIGN KEY (agent_id) REFERENCES public.active_matrix_agents(id) ON DELETE CASCADE;


--
-- Name: active_matrix_rooms fk_rails_64e23796e5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_rooms
    ADD CONSTRAINT fk_rails_64e23796e5 FOREIGN KEY (agent_id) REFERENCES public.active_matrix_agents(id) ON DELETE CASCADE;


--
-- Name: active_matrix_room_state fk_rails_65ec2185e0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_room_state
    ADD CONSTRAINT fk_rails_65ec2185e0 FOREIGN KEY (agent_id, room_id) REFERENCES public.active_matrix_rooms(agent_id, room_id) ON DELETE CASCADE;


--
-- Name: active_matrix_agent_messages fk_rails_6d3251e606; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_agent_messages
    ADD CONSTRAINT fk_rails_6d3251e606 FOREIGN KEY (to_agent_id) REFERENCES public.active_matrix_agents(id) ON DELETE CASCADE;


--
-- Name: active_matrix_outbox fk_rails_78073f7f2f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_outbox
    ADD CONSTRAINT fk_rails_78073f7f2f FOREIGN KEY (agent_id) REFERENCES public.active_matrix_agents(id) ON DELETE CASCADE;


--
-- Name: active_matrix_memories fk_rails_9addb81a36; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_memories
    ADD CONSTRAINT fk_rails_9addb81a36 FOREIGN KEY (agent_id) REFERENCES public.active_matrix_agents(id) ON DELETE CASCADE;


--
-- Name: active_matrix_room_members fk_rails_c72ada4560; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_room_members
    ADD CONSTRAINT fk_rails_c72ada4560 FOREIGN KEY (agent_id, room_id) REFERENCES public.active_matrix_rooms(agent_id, room_id) ON DELETE CASCADE;


--
-- Name: active_matrix_agent_messages fk_rails_fc7929d068; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_agent_messages
    ADD CONSTRAINT fk_rails_fc7929d068 FOREIGN KEY (from_agent_id) REFERENCES public.active_matrix_agents(id) ON DELETE SET NULL;


--
-- Name: active_matrix_memories fk_rails_fe47344d8f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_matrix_memories
    ADD CONSTRAINT fk_rails_fe47344d8f FOREIGN KEY (chat_session_id) REFERENCES public.active_matrix_chat_sessions(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


