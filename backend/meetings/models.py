import secrets

from django.conf import settings
from django.db import models


def new_meeting_code():
    return secrets.token_urlsafe(9)


def new_participant_token():
    return secrets.token_urlsafe(32)


class Meeting(models.Model):
    class Status(models.TextChoices):
        CREATED = "created"
        LIVE = "live"
        ENDED = "ended"

    code = models.CharField(max_length=32, unique=True, default=new_meeting_code, editable=False)
    title = models.CharField(max_length=200, blank=True)
    host = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="hosted_meetings")
    # Feature 2: compiler toggle. Defaults ON so it is not forgotten.
    console_enabled = models.BooleanField(default=True)
    # Feature 15: problem statement shown beside the editor.
    problem_statement = models.TextField(blank=True)
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.CREATED)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.title or 'Meeting'} ({self.code})"


class Participant(models.Model):
    class Role(models.TextChoices):
        HOST = "host"
        INTERVIEWER = "interviewer"
        CANDIDATE = "candidate"

    class Status(models.TextChoices):
        WAITING = "waiting"
        ADMITTED = "admitted"
        REJECTED = "rejected"

    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name="participants")
    user = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL)
    name = models.CharField(max_length=100)
    role = models.CharField(max_length=12, choices=Role.choices, default=Role.CANDIDATE)
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.WAITING)
    # Secret for link-only guests (candidates). Never shown to other participants.
    token = models.CharField(max_length=64, unique=True, default=new_participant_token, editable=False)
    online = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.name} [{self.role}/{self.status}]"

    def public_dict(self):
        """Safe to send to other participants. Never includes the token."""
        return {"id": self.id, "name": self.name, "role": self.role, "status": self.status}
