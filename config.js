// Supabase project settings. Both values are safe to publish: the database's
// access rules (supabase/schema.sql) decide what each signed-in person can see and change.
// Find them in Supabase under Project Settings > API Keys (publishable key).
window.MOVIE_CLUB = {
  supabaseUrl: "https://pbgedfapgvmvyzsdblab.supabase.co",
  supabaseAnonKey: "sb_publishable_m8bxU98WLs9Ax2hOMxDT2A_Mqu7F57G",
  // TMDB (themoviedb.org) API key: film search, posters and details. Read-only, safe to publish.
  // Leave empty to turn film search off (people can still type film details in by hand).
  tmdbApiKey: ""
};
