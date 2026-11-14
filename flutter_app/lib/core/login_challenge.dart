import 'user_model.dart';

/// What `POST /auth/login` gave back.
sealed class LoginResult {
  const LoginResult();
}

/// A normal session (two-step sign-in off, or an older backend).
class LoginSession extends LoginResult {
  final String token;
  final User user;
  const LoginSession({required this.token, required this.user});
}

/// Two-step sign-in is on: no session yet. The code screen sends a code to
/// [email] (the one typed on the login form) and trades it for a session.
class LoginChallenge extends LoginResult {
  final String challengeToken;
  final String email;
  const LoginChallenge({required this.challengeToken, required this.email});
}
