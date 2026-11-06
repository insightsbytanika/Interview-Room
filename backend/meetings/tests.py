from channels.db import database_sync_to_async
from channels.testing import WebsocketCommunicator
from django.test import TransactionTestCase
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import AccessToken

from accounts.models import User
from config.asgi import application
from meetings.models import Meeting


class RestFlowTests(TransactionTestCase):
    def setUp(self):
        self.client = APIClient()

    def test_register_login_create_meeting_and_guest_join(self):
        r = self.client.post("/api/auth/register/", {"email": "a@b.com", "password": "Sup3rSecret!x"})
        self.assertEqual(r.status_code, 201)
        r = self.client.post("/api/auth/login/", {"username": "a@b.com", "password": "Sup3rSecret!x"})
        self.assertEqual(r.status_code, 200)
        access = r.data["access"]

        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {access}")
        r = self.client.post("/api/meetings/", {"title": "Backend round"})
        self.assertEqual(r.status_code, 201)
        self.assertTrue(r.data["console_enabled"])  # default ON
        code = r.data["code"]

        # Guest needs no auth.
        guest = APIClient()
        self.assertEqual(guest.get(f"/api/meetings/{code}/public/").status_code, 200)
        r = guest.post(f"/api/meetings/{code}/join/", {"name": "Asha"})
        self.assertEqual(r.status_code, 201)
        self.assertIn("participant_token", r.data)

        # Guest cannot read host-only meeting detail.
        self.assertEqual(guest.get(f"/api/meetings/{code}/").status_code, 401)


class SignalingTests(TransactionTestCase):
    async def _setup(self):
        host = await database_sync_to_async(User.objects.create_user)(
            username="h@x.com", email="h@x.com", password="pw12345678!"
        )
        meeting = await database_sync_to_async(Meeting.objects.create)(host=host, title="T", problem_statement="Two sum")
        jwt = str(AccessToken.for_user(host))
        return host, meeting, jwt

    async def test_waiting_room_admit_signal_and_console_toggle(self):
        from meetings.models import Participant

        host, meeting, jwt = await self._setup()
        code = meeting.code

        hc = WebsocketCommunicator(application, f"/ws/meetings/{code}/?jwt={jwt}")
        ok, _ = await hc.connect()
        self.assertTrue(ok)
        state = await hc.receive_json_from()
        self.assertEqual(state["type"], "state")
        self.assertEqual(state["you"]["role"], "host")
        self.assertEqual(state["problem_statement"], "Two sum")

        cand = await database_sync_to_async(Participant.objects.create)(meeting=meeting, name="Asha")
        cc = WebsocketCommunicator(application, f"/ws/meetings/{code}/?ptoken={cand.token}")
        ok, _ = await cc.connect()
        self.assertTrue(ok)
        self.assertEqual((await cc.receive_json_from())["type"], "waiting")

        req = await hc.receive_json_from()
        self.assertEqual(req["type"], "join_request")
        self.assertEqual(req["participant"]["id"], cand.id)
        self.assertNotIn("token", req["participant"])

        # Waiting candidates cannot signal.
        await cc.send_json_to({"type": "signal", "to": 1, "data": {}})
        self.assertEqual((await cc.receive_json_from())["type"], "error")

        await hc.send_json_to({"type": "admit", "participant_id": cand.id})
        self.assertEqual((await cc.receive_json_from())["type"], "admitted")
        cstate = await cc.receive_json_from()
        self.assertEqual(cstate["type"], "state")
        self.assertEqual(len(cstate["peers"]), 1)
        self.assertEqual((await hc.receive_json_from())["type"], "peer_joined")

        # Signaling relay host -> candidate.
        await hc.send_json_to({"type": "signal", "to": cand.id, "data": {"sdp": "offer"}})
        sig = await cc.receive_json_from()
        self.assertEqual(sig["type"], "signal")
        self.assertEqual(sig["data"], {"sdp": "offer"})

        # Console toggle: host only, persisted, broadcast.
        await cc.send_json_to({"type": "console_toggle", "enabled": False})
        self.assertEqual((await cc.receive_json_from())["type"], "error")
        await hc.send_json_to({"type": "console_toggle", "enabled": False})
        self.assertFalse((await cc.receive_json_from())["enabled"])
        await hc.receive_json_from()
        refreshed = await database_sync_to_async(Meeting.objects.get)(pk=meeting.pk)
        self.assertFalse(refreshed.console_enabled)

        await hc.disconnect()
        await cc.disconnect()

    async def test_bad_token_rejected(self):
        host, meeting, jwt = await self._setup()
        c = WebsocketCommunicator(application, f"/ws/meetings/{meeting.code}/?ptoken=nope")
        ok, _ = await c.connect()
        self.assertFalse(ok)
