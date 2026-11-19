import 'login_challenge.dart';
import 'user_model.dart';

/// What `POST /auth/google` gave back (Continue with Google). Kept apart from
/// [LoginResult] so the password sign-in switches stay as they are.
sealed class GoogleSignInResult {
  const GoogleSignInResult();
}

/// Signed in. [created]: a new Nexus account was made for this Google account.
class GoogleSession extends GoogleSignInResult {
  final String token;
  final User user;
  final bool created;
  const GoogleSession({required this.token, required this.user, this.created = false});
}

/// Two-step sign-in is on for the account: the code screen finishes it.
class GoogleChallenge extends GoogleSignInResult {
  final LoginChallenge challenge;
  const GoogleChallenge(this.challenge);
}

/// The Google email already has a Nexus account: its password is needed once
/// to connect Google. [wrongPassword]: the password just sent didn't match.
class GooglePasswordNeeded extends GoogleSignInResult {
  final String email;
  final String message;
  final bool wrongPassword;
  const GooglePasswordNeeded({required this.email, required this.message, this.wrongPassword = false});
}

/// The Google token held for the password step is gone (10 minutes passed):
/// nothing was sent, Continue with Google has to run again.
class GoogleTokenExpired extends GoogleSignInResult {
  const GoogleTokenExpired();
}
