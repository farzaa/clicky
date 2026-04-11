import enum
import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class TimestampedModel:
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class WorkspaceMembershipRole(str, enum.Enum):
    owner = "owner"
    editor = "editor"
    viewer = "viewer"


class WorkspaceEntryType(str, enum.Enum):
    directory = "directory"
    file = "file"


class WorkspaceContentType(str, enum.Enum):
    markdown = "markdown"
    pdf = "pdf"
    image = "image"
    text = "text"
    other = "other"


class WorkspaceLaunchState(str, enum.Enum):
    stopped = "stopped"
    running = "running"


class WorkspaceIngestionJobStatus(str, enum.Enum):
    queued = "queued"
    running = "running"
    completed = "completed"
    failed = "failed"


class User(Base, TimestampedModel):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    authentication_subject_identifier: Mapped[str | None] = mapped_column(
        String(255),
        unique=True,
        index=True,
        nullable=True,
    )
    email_address: Mapped[str | None] = mapped_column(
        String(320),
        unique=True,
        index=True,
        nullable=True,
    )
    display_name: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    avatar_image_url: Mapped[str | None] = mapped_column(
        String(2048),
        nullable=True,
    )
    password_hash: Mapped[str | None] = mapped_column(
        String(512),
        nullable=True,
    )
    profile_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    owned_workspaces: Mapped[list["Workspace"]] = relationship(
        back_populates="owner_user",
    )
    workspace_memberships: Mapped[list["WorkspaceMembership"]] = relationship(
        back_populates="user",
    )
    auth_sessions: Mapped[list["AuthSession"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )
    created_workspace_entries: Mapped[list["WorkspaceEntry"]] = relationship(
        back_populates="created_by_user",
    )
    created_courses: Mapped[list["Course"]] = relationship(
        back_populates="created_by_user",
    )
    created_learner_topic_masteries: Mapped[list["LearnerTopicMastery"]] = relationship(
        back_populates="created_by_user",
        foreign_keys="LearnerTopicMastery.created_by_user_id",
    )
    updated_learner_topic_masteries: Mapped[list["LearnerTopicMastery"]] = relationship(
        back_populates="updated_by_user",
        foreign_keys="LearnerTopicMastery.updated_by_user_id",
    )
    created_learner_observations: Mapped[list["LearnerObservation"]] = relationship(
        back_populates="created_by_user",
    )
    created_agents: Mapped[list["Agent"]] = relationship(
        back_populates="created_by_user",
    )
    created_agent_sessions: Mapped[list["AgentSession"]] = relationship(
        back_populates="created_by_user",
    )
    created_agent_session_messages: Mapped[list["AgentSessionMessage"]] = relationship(
        back_populates="created_by_user",
    )
    created_workspace_ingestion_jobs: Mapped[list["WorkspaceIngestionJob"]] = relationship(
        back_populates="created_by_user",
    )


class Workspace(Base, TimestampedModel):
    __tablename__ = "workspaces"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    display_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    description: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    workspace_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )
    launch_state: Mapped[WorkspaceLaunchState] = mapped_column(
        Enum(
            WorkspaceLaunchState,
            name="workspace_launch_state",
        ),
        default=WorkspaceLaunchState.stopped,
        nullable=False,
    )
    launched_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    last_opened_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    owner_user: Mapped["User"] = relationship(back_populates="owned_workspaces")
    workspace_memberships: Mapped[list["WorkspaceMembership"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    workspace_entries: Mapped[list["WorkspaceEntry"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    courses: Mapped[list["Course"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    learner_topic_masteries: Mapped[list["LearnerTopicMastery"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    learner_observations: Mapped[list["LearnerObservation"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    agents: Mapped[list["Agent"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    agent_sessions: Mapped[list["AgentSession"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    agent_session_messages: Mapped[list["AgentSessionMessage"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    ingestion_jobs: Mapped[list["WorkspaceIngestionJob"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )


class Course(Base, TimestampedModel):
    __tablename__ = "courses"
    __table_args__ = (
        UniqueConstraint(
            "workspace_id",
            "root_entry_path",
            name="uq_courses_workspace_root_entry_path",
        ),
        Index(
            "ix_courses_workspace_updated_at",
            "workspace_id",
            "updated_at",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    display_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    root_entry_path: Mapped[str] = mapped_column(
        String(4096),
        nullable=False,
    )
    last_activity_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    course_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="courses")
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_courses",
    )
    learner_topic_masteries: Mapped[list["LearnerTopicMastery"]] = relationship(
        back_populates="course",
        cascade="all, delete-orphan",
    )
    learner_observations: Mapped[list["LearnerObservation"]] = relationship(
        back_populates="course",
        cascade="all, delete-orphan",
    )


class LearnerTopicMastery(Base, TimestampedModel):
    __tablename__ = "learner_topic_masteries"
    __table_args__ = (
        UniqueConstraint(
            "course_id",
            "topic_key",
            name="uq_learner_topic_masteries_course_topic_key",
        ),
        Index(
            "ix_learner_topic_masteries_workspace_course",
            "workspace_id",
            "course_id",
        ),
        Index(
            "ix_learner_topic_masteries_course_updated_at",
            "course_id",
            "updated_at",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    course_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("courses.id", ondelete="CASCADE"),
        nullable=False,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    updated_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    topic_key: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    topic_title: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    mastery_score: Mapped[int] = mapped_column(
        BigInteger,
        nullable=False,
    )
    confidence_score: Mapped[int] = mapped_column(
        BigInteger,
        nullable=False,
    )
    strength_notes: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    gap_notes: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    explanation_strategy: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    prerequisite_topic_keys: Mapped[list] = mapped_column(
        JSONB,
        default=list,
        nullable=False,
    )
    evidence_summary: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    times_assessed: Mapped[int] = mapped_column(
        BigInteger,
        default=1,
        nullable=False,
    )
    last_assessed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    mastery_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="learner_topic_masteries")
    course: Mapped["Course"] = relationship(back_populates="learner_topic_masteries")
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_learner_topic_masteries",
        foreign_keys=[created_by_user_id],
    )
    updated_by_user: Mapped["User | None"] = relationship(
        back_populates="updated_learner_topic_masteries",
        foreign_keys=[updated_by_user_id],
    )
    learner_observations: Mapped[list["LearnerObservation"]] = relationship(
        back_populates="topic_mastery",
    )


class LearnerObservation(Base, TimestampedModel):
    __tablename__ = "learner_observations"
    __table_args__ = (
        Index(
            "ix_learner_observations_workspace_created_at",
            "workspace_id",
            "created_at",
        ),
        Index(
            "ix_learner_observations_course_created_at",
            "course_id",
            "created_at",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    course_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("courses.id", ondelete="CASCADE"),
        nullable=False,
    )
    topic_mastery_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("learner_topic_masteries.id", ondelete="SET NULL"),
        nullable=True,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    agent_session_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("agent_sessions.id", ondelete="SET NULL"),
        nullable=True,
    )
    agent_session_message_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("agent_session_messages.id", ondelete="SET NULL"),
        nullable=True,
    )
    topic_key: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    observation_text: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    evidence_excerpt: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    assessed_mastery_score: Mapped[int | None] = mapped_column(
        BigInteger,
        nullable=True,
    )
    assessed_confidence_score: Mapped[int | None] = mapped_column(
        BigInteger,
        nullable=True,
    )
    observation_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="learner_observations")
    course: Mapped["Course"] = relationship(back_populates="learner_observations")
    topic_mastery: Mapped["LearnerTopicMastery | None"] = relationship(
        back_populates="learner_observations",
    )
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_learner_observations",
    )
    agent_session: Mapped["AgentSession | None"] = relationship(
        back_populates="learner_observations",
    )
    agent_session_message: Mapped["AgentSessionMessage | None"] = relationship(
        back_populates="learner_observations",
    )


class WorkspaceMembership(Base, TimestampedModel):
    __tablename__ = "workspace_memberships"
    __table_args__ = (
        UniqueConstraint(
            "workspace_id",
            "user_id",
            name="uq_workspace_memberships_workspace_user",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    role: Mapped[WorkspaceMembershipRole] = mapped_column(
        Enum(
            WorkspaceMembershipRole,
            name="workspace_membership_role",
        ),
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="workspace_memberships")
    user: Mapped["User"] = relationship(back_populates="workspace_memberships")


class WorkspaceEntry(Base, TimestampedModel):
    __tablename__ = "workspace_entries"
    __table_args__ = (
        UniqueConstraint(
            "workspace_id",
            "entry_path",
            name="uq_workspace_entries_workspace_path",
        ),
        Index(
            "ix_workspace_entries_workspace_parent",
            "workspace_id",
            "parent_entry_id",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    parent_entry_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspace_entries.id", ondelete="CASCADE"),
        nullable=True,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    entry_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    entry_path: Mapped[str] = mapped_column(
        String(4096),
        nullable=False,
    )
    entry_type: Mapped[WorkspaceEntryType] = mapped_column(
        Enum(
            WorkspaceEntryType,
            name="workspace_entry_type",
        ),
        nullable=False,
    )
    content_type: Mapped[WorkspaceContentType | None] = mapped_column(
        Enum(
            WorkspaceContentType,
            name="workspace_content_type",
        ),
        nullable=True,
    )
    mime_type: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    size_bytes: Mapped[int | None] = mapped_column(
        BigInteger,
        nullable=True,
    )
    content_sha256: Mapped[str | None] = mapped_column(
        String(64),
        nullable=True,
    )
    text_content: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    binary_content: Mapped[bytes | None] = mapped_column(
        LargeBinary,
        nullable=True,
    )
    storage_object_key: Mapped[str | None] = mapped_column(
        String(2048),
        nullable=True,
    )
    entry_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="workspace_entries")
    parent_entry: Mapped["WorkspaceEntry | None"] = relationship(
        remote_side="WorkspaceEntry.id",
        back_populates="child_entries",
    )
    child_entries: Mapped[list["WorkspaceEntry"]] = relationship(
        back_populates="parent_entry",
        cascade="all, delete-orphan",
    )
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_workspace_entries",
    )
    ingestion_jobs: Mapped[list["WorkspaceIngestionJob"]] = relationship(
        back_populates="source_workspace_entry",
    )


class WorkspaceIngestionJob(Base, TimestampedModel):
    __tablename__ = "workspace_ingestion_jobs"
    __table_args__ = (
        Index(
            "ix_workspace_ingestion_jobs_workspace_created_at",
            "workspace_id",
            "created_at",
        ),
        Index(
            "ix_workspace_ingestion_jobs_workspace_source_path",
            "workspace_id",
            "source_entry_path",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    source_entry_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspace_entries.id", ondelete="CASCADE"),
        nullable=False,
    )
    source_entry_path: Mapped[str] = mapped_column(
        String(4096),
        nullable=False,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    status: Mapped[WorkspaceIngestionJobStatus] = mapped_column(
        Enum(
            WorkspaceIngestionJobStatus,
            name="workspace_ingestion_job_status",
        ),
        default=WorkspaceIngestionJobStatus.queued,
        nullable=False,
    )
    status_message: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    output_bundle_path: Mapped[str | None] = mapped_column(
        String(4096),
        nullable=True,
    )
    started_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    completed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    job_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="ingestion_jobs")
    source_workspace_entry: Mapped["WorkspaceEntry"] = relationship(
        back_populates="ingestion_jobs",
    )
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_workspace_ingestion_jobs",
    )


class AuthSession(Base, TimestampedModel):
    __tablename__ = "auth_sessions"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    session_token_hash: Mapped[str] = mapped_column(
        String(64),
        unique=True,
        index=True,
        nullable=False,
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    last_used_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    user: Mapped["User"] = relationship(back_populates="auth_sessions")


class Agent(Base, TimestampedModel):
    __tablename__ = "agents"
    __table_args__ = (
        Index(
            "ix_agents_workspace_created_at",
            "workspace_id",
            "created_at",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    display_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    description: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    provider: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    model: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    system_prompt: Mapped[str] = mapped_column(
        Text,
        default="",
        nullable=False,
    )
    agent_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="agents")
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_agents",
    )
    agent_sessions: Mapped[list["AgentSession"]] = relationship(
        back_populates="agent",
    )


class AgentSession(Base, TimestampedModel):
    __tablename__ = "agent_sessions"
    __table_args__ = (
        Index(
            "ix_agent_sessions_workspace_updated_at",
            "workspace_id",
            "updated_at",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    agent_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("agents.id", ondelete="SET NULL"),
        nullable=True,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    display_name: Mapped[str] = mapped_column(
        String(255),
        default="New session",
        nullable=False,
    )
    last_message_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    session_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="agent_sessions")
    agent: Mapped["Agent | None"] = relationship(back_populates="agent_sessions")
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_agent_sessions",
    )
    messages: Mapped[list["AgentSessionMessage"]] = relationship(
        back_populates="agent_session",
        cascade="all, delete-orphan",
    )
    learner_observations: Mapped[list["LearnerObservation"]] = relationship(
        back_populates="agent_session",
    )


class AgentSessionMessage(Base, TimestampedModel):
    __tablename__ = "agent_session_messages"
    __table_args__ = (
        UniqueConstraint(
            "agent_session_id",
            "sequence_index",
            name="uq_agent_session_messages_sequence",
        ),
        Index(
            "ix_agent_session_messages_session_sequence",
            "agent_session_id",
            "sequence_index",
        ),
        Index(
            "ix_agent_session_messages_workspace_created_at",
            "workspace_id",
            "created_at",
        ),
        Index(
            "ix_agent_session_messages_run_id",
            "run_id",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    agent_session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("agent_sessions.id", ondelete="CASCADE"),
        nullable=False,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    run_id: Mapped[str | None] = mapped_column(
        String(128),
        nullable=True,
    )
    sequence_index: Mapped[int] = mapped_column(
        BigInteger,
        nullable=False,
    )
    role: Mapped[str] = mapped_column(
        String(32),
        nullable=False,
    )
    name: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    tool_call_id: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    provider_response_id: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    content: Mapped[str] = mapped_column(
        Text,
        default="",
        nullable=False,
    )
    images_payload: Mapped[list] = mapped_column(
        JSONB,
        default=list,
        nullable=False,
    )
    tool_calls_payload: Mapped[list] = mapped_column(
        JSONB,
        default=list,
        nullable=False,
    )
    message_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="agent_session_messages")
    agent_session: Mapped["AgentSession"] = relationship(back_populates="messages")
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_agent_session_messages",
    )
    learner_observations: Mapped[list["LearnerObservation"]] = relationship(
        back_populates="agent_session_message",
    )
