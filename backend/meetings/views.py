from django.shortcuts import get_object_or_404
from rest_framework import generics, permissions, status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Meeting, Participant
from .serializers import JoinSerializer, MeetingSerializer, PublicMeetingSerializer


class MeetingListCreateView(generics.ListCreateAPIView):
    """Interviewer dashboard: list own meetings, create a new one."""

    serializer_class = MeetingSerializer

    def get_queryset(self):
        return Meeting.objects.filter(host=self.request.user)

    def perform_create(self, serializer):
        serializer.save(host=self.request.user)


class MeetingDetailView(generics.RetrieveUpdateAPIView):
    """Host-only: edit title, problem statement, console toggle."""

    serializer_class = MeetingSerializer
    lookup_field = "code"

    def get_queryset(self):
        return Meeting.objects.filter(host=self.request.user)


class PublicMeetingView(APIView):
    """Candidate landing page: check the link is valid before asking for a name."""

    permission_classes = [permissions.AllowAny]
    authentication_classes: list = []

    def get(self, request, code):
        meeting = get_object_or_404(Meeting, code=code)
        if meeting.status == Meeting.Status.ENDED:
            return Response({"detail": "This interview has ended."}, status=status.HTTP_410_GONE)
        return Response(PublicMeetingSerializer(meeting).data)


class JoinView(APIView):
    """Link-only candidate joins the waiting room. No account required.

    Returns a participant token the client then uses to open the WebSocket.
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes: list = []

    def post(self, request, code):
        meeting = get_object_or_404(Meeting, code=code)
        if meeting.status == Meeting.Status.ENDED:
            return Response({"detail": "This interview has ended."}, status=status.HTTP_410_GONE)
        serializer = JoinSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        participant = Participant.objects.create(
            meeting=meeting,
            name=serializer.validated_data["name"].strip(),
            role=Participant.Role.CANDIDATE,
            status=Participant.Status.WAITING,
        )
        return Response(
            {"participant_id": participant.id, "participant_token": participant.token},
            status=status.HTTP_201_CREATED,
        )
