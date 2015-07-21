local schema = require("lapis.db.schema")
local types = schema.types

return {
  [1] = function()
    schema.create_table("user", {
      { "id", types.text },
      { "username", types.text },
      { "email", types.text },
      { "passwordHash", types.text },
      { "active", types.boolean},
    })
    schema.create_table("post", {
      { "id", types.text },
      { "title", types.text },
      { "link", types.text },
      { "text", types.text },
    })
    schema.create_table("tag", {
      { "id", types.text },
      { "name", types.text },
      { "title", types.text },
      { "description", types.text }
    })
    schema.create_table("itemtags", {
      { "itemID", types.text },
      { "tagID", types.text },
      { "up", types.integer },
      { "down", types.integer },
      { "date", types.integer }
    })
    schema.create_table("comment", {
      { "id", types.text },
      { "userID", types.text },
      { "username", types.integer },
      { "text", types.integer },
      { "date", types.integer }
    })
    schema.create_table("node", {
      { "id", types.text }
    })
    schema.create_table('nodeposts',{
      {'nodeID',types.text},
      {'postID',types.text}
    }
    )
  end
}
