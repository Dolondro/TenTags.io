local config = require("lapis.config")

config("development", {
  mysql = {
    host = "127.0.0.1",
    user = "root",
    password = "meep",
    database = "taggr",
  },

  session_name = 'filtta_session',
  secret = "this is my secrarstrstet string 123456",
  num_workers = '1',
  port = 8080
})

config("production", {
  mysql = {
    host = "127.0.0.1",
    user = "root",
    password = "meep",
    database = "taggr"
  },
  logging = {
    queries = false,
    requests = false
  },
  code_cache = "on",
  secret = "this is my secrarstrstet string 123456",
  port = 80,
  num_workers = 'auto',
  logging = {
    queries = false,
    requests = false
  }
})