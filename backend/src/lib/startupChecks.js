// Checks that stop the server from starting with an unsafe setup. Pure
// functions of the environment, so they can be unit-tested.

// On Render (it sets RENDER=true on every service) or with
// NODE_ENV=production, JWT_SECRET must be set and at least 32 characters.
function jwtSecretProblem(env) {
  const deployed = env.NODE_ENV === 'production' || env.RENDER === 'true';
  if (deployed && (!env.JWT_SECRET || env.JWT_SECRET.length < 32)) {
    return 'JWT_SECRET is missing or shorter than 32 characters.';
  }
  return null;
}

module.exports = { jwtSecretProblem };
