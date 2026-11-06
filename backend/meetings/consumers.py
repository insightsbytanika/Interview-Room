"""WebSocket consumer: waiting room, WebRTC signaling relay, console toggle.

Connect:  ws://host/ws/meetings/<code>/?jwt=<access token>        (host)
          ws://host/ws/meetings/<code>/?ptoken=<participant token> (candidate)

Client -> server
  {"type": "admit",  "participant_id": N}          host only
  {"type": "reject", "participant_id": N}          host only
  {"type": "signal", "to": N, "data": {...}}       offer / answer / ice, admitted only
  {"type": "console_toggle", "enabled": bool}      host only

Server -> client
  state, join_request, admitted, rejected, peer_joined, peer_left,
  signal, console_toggled, error
"""
from urllib.parse import parse_qs

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from rest_framework_simplejwt.exceptions import TokenError
from rest_framework_simplejwt.tokens import AccessToken

from .models import Meeting, Participant


class MeetingConsumer(AsyncJsonWebsocketConsumer):
    # ---- group names -------------------------------------------------
    @property
    def room_group(self):
        return f"meeting_{self.code}"

    @property
    def host_group(self):
        return f"meeting_{self.code}_host"

    def participant_group(self, pid):
        return f"participant_{pid}"

    # ---- lifecycle ---------------------------------------------------
    async def connect(self):
        self.code = self.scope["url_route"]["kwargs"]["code"]
        self.participant = None
        self.meeting = None

        params = parse_qs(self.scope["query_string"].decode())
        jwt = (params.get("jwt") or [None])[0]
        ptoken = (params.get("ptoken") or [None])[0]

        self.meeting, self.participant = await self._authenticate(jwt, ptoken)
        if not self.participant:
            await self.close(code=4401)
            return

        await self.accept()
        await self.channel_layer.group_add(self.participant_group(self.participant.id), self.channel_name)
        await self._set_online(True)

        if self.participant.status == Participant.Status.ADMITTED:
            await self._enter_room()
        elif self.participant.status == Participant.Status.WAITING:
            await self.channel_layer.group_send(
                self.host_group,
                {"type": "relay.event", "payload": {"type": "join_request", "participant": self.participant.public_dict()}},
            )
            await self.send_json({"type": "waiting"})
        else:
            await self.send_json({"type": "rejected"})
            await self.close(code=4403)

    async def disconnect(self, code):
        if not self.participant:
            return
        await self._set_online(False)
        if self.participant.status == Participant.Status.ADMITTED:
            await self.channel_layer.group_send(
                self.room_group,
                {
                    "type": "relay.event",
                    "payload": {"type": "peer_left", "participant_id": self.participant.id},
                    "exclude": self.participant.id,
                },
            )
            await self.channel_layer.group_discard(self.room_group, self.channel_name)
        if self.participant.role == Participant.Role.HOST:
            await self.channel_layer.group_discard(self.host_group, self.channel_name)
        await self.channel_layer.group_discard(self.participant_group(self.participant.id), self.channel_name)

    # ---- incoming ----------------------------------------------------
    async def receive_json(self, content, **kwargs):
        mtype = content.get("type")
        is_host = self.participant.role == Participant.Role.HOST
        admitted = self.participant.status == Participant.Status.ADMITTED

        if mtype in ("admit", "reject"):
            if not is_host:
                return await self.send_json({"type": "error", "detail": "Host only."})
            await self._handle_admit_reject(mtype, content.get("participant_id"))

        elif mtype == "signal":
            if not admitted:
                return await self.send_json({"type": "error", "detail": "Not admitted."})
            target = content.get("to")
            if not await self._is_admitted_in_room(target):
                return await self.send_json({"type": "error", "detail": "Unknown peer."})
            await self.channel_layer.group_send(
                self.participant_group(target),
                {
                    "type": "relay.event",
                    "payload": {"type": "signal", "from": self.participant.id, "data": content.get("data")},
                },
            )

        elif mtype == "console_toggle":
            if not is_host:
                return await self.send_json({"type": "error", "detail": "Host only."})
            enabled = bool(content.get("enabled"))
            await self._set_console(enabled)
            await self.channel_layer.group_send(
                self.room_group,
                {"type": "relay.event", "payload": {"type": "console_toggled", "enabled": enabled}},
            )

        else:
            await self.send_json({"type": "error", "detail": "Unknown message type."})

    # ---- group event handlers ---------------------------------------
    async def relay_event(self, event):
        if event.get("exclude") == self.participant.id:
            return
        await self.send_json(event["payload"])

    async def admit_granted(self, event):
        """Sent to the admitted participant's own group."""
        self.participant.status = Participant.Status.ADMITTED
        await self.send_json({"type": "admitted"})
        await self._enter_room()

    async def admit_denied(self, event):
        self.participant.status = Participant.Status.REJECTED
        await self.send_json({"type": "rejected"})
        await self.close(code=4403)

    # ---- helpers -----------------------------------------------------
    async def _enter_room(self):
        await self.channel_layer.group_add(self.room_group, self.channel_name)
        if self.participant.role == Participant.Role.HOST:
            await self.channel_layer.group_add(self.host_group, self.channel_name)
        state = await self._build_state()
        await self.send_json(state)
        await self.channel_layer.group_send(
            self.room_group,
            {
                "type": "relay.event",
                "payload": {"type": "peer_joined", "participant": self.participant.public_dict()},
                "exclude": self.participant.id,
            },
        )

    async def _handle_admit_reject(self, mtype, pid):
        target = await self._get_waiting_participant(pid)
        if not target:
            return await self.send_json({"type": "error", "detail": "No such waiting participant."})
        new_status = Participant.Status.ADMITTED if mtype == "admit" else Participant.Status.REJECTED
        await self._set_status(target.id, new_status)
        event = "admit.granted" if mtype == "admit" else "admit.denied"
        await self.channel_layer.group_send(self.participant_group(target.id), {"type": event})

    # ---- DB access ---------------------------------------------------
    @database_sync_to_async
    def _authenticate(self, jwt, ptoken):
        meeting = Meeting.objects.filter(code=self.code).select_related("host").first()
        if not meeting or meeting.status == Meeting.Status.ENDED:
            return None, None

        if jwt:
            try:
                user_id = AccessToken(jwt)["user_id"]
            except (TokenError, KeyError):
                return None, None
            if str(meeting.host_id) != str(user_id):
                return None, None  # extra interviewers come in a later phase
            participant, _ = Participant.objects.get_or_create(
                meeting=meeting,
                user=meeting.host,
                role=Participant.Role.HOST,
                defaults={"name": meeting.host.first_name or meeting.host.email, "status": Participant.Status.ADMITTED},
            )
            if meeting.status == Meeting.Status.CREATED:
                meeting.status = Meeting.Status.LIVE
                meeting.save(update_fields=["status"])
            return meeting, participant

        if ptoken:
            participant = Participant.objects.filter(meeting=meeting, token=ptoken).first()
            return (meeting, participant) if participant else (None, None)

        return None, None

    @database_sync_to_async
    def _set_online(self, value):
        Participant.objects.filter(pk=self.participant.pk).update(online=value)

    @database_sync_to_async
    def _set_status(self, pid, status):
        Participant.objects.filter(pk=pid, meeting=self.meeting).update(status=status)

    @database_sync_to_async
    def _get_waiting_participant(self, pid):
        return Participant.objects.filter(
            pk=pid, meeting=self.meeting, status=Participant.Status.WAITING
        ).first()

    @database_sync_to_async
    def _is_admitted_in_room(self, pid):
        return Participant.objects.filter(
            pk=pid, meeting=self.meeting, status=Participant.Status.ADMITTED, online=True
        ).exists()

    @database_sync_to_async
    def _set_console(self, enabled):
        Meeting.objects.filter(pk=self.meeting.pk).update(console_enabled=enabled)

    @database_sync_to_async
    def _build_state(self):
        meeting = Meeting.objects.get(pk=self.meeting.pk)
        peers = [
            p.public_dict()
            for p in meeting.participants.filter(status=Participant.Status.ADMITTED, online=True).exclude(
                pk=self.participant.pk
            )
        ]
        state = {
            "type": "state",
            "you": self.participant.public_dict(),
            "peers": peers,
            "console_enabled": meeting.console_enabled,
            "title": meeting.title,
        }
        # Problem statement only goes to admitted participants.
        state["problem_statement"] = meeting.problem_statement
        if self.participant.role == Participant.Role.HOST:
            state["waiting"] = [
                p.public_dict() for p in meeting.participants.filter(status=Participant.Status.WAITING, online=True)
            ]
        return state
