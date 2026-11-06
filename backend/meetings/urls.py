from django.urls import path

from .views import JoinView, MeetingDetailView, MeetingListCreateView, PublicMeetingView

urlpatterns = [
    path("", MeetingListCreateView.as_view()),
    path("<str:code>/", MeetingDetailView.as_view()),
    path("<str:code>/public/", PublicMeetingView.as_view()),
    path("<str:code>/join/", JoinView.as_view()),
]
