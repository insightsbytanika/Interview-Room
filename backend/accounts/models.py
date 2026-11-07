from django.contrib.auth.models import AbstractUser
from django.db import models


class User(AbstractUser):
    """Custom user from day one so we can extend it later (theme, profile, etc.)."""

    email = models.EmailField(unique=True)
    theme = models.CharField(
        max_length=10,
        choices=[("light", "Light"), ("dark", "Dark"), ("system", "System")],
        default="system",
    )

    def __str__(self):
        return self.email or self.username