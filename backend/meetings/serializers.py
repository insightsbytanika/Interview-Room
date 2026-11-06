from rest_framework import serializers

from .models import Meeting


class MeetingSerializer(serializers.ModelSerializer):
    class Meta:
        model = Meeting
        fields = ("id", "code", "title", "console_enabled", "problem_statement", "status", "created_at")
        read_only_fields = ("id", "code", "status", "created_at")
        # Explicit default so the console stays ON even if a client omits the field
        # (DRF treats a missing boolean in form-encoded input as False otherwise).
        extra_kwargs = {"console_enabled": {"default": True}}


class PublicMeetingSerializer(serializers.ModelSerializer):
    """What a not-yet-admitted candidate may see. No problem statement."""

    class Meta:
        model = Meeting
        fields = ("code", "title", "status")


class JoinSerializer(serializers.Serializer):
    name = serializers.CharField(max_length=100)
