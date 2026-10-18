import sqlite3

c = sqlite3.connect(r"d:/Code/ATzotero.koplugin/_tmp_zotero.db").cursor()
print("itemTypes:", list(c.execute("SELECT * FROM itemTypes")))
print(
    "attachments:",
    list(
        c.execute(
            "SELECT items.key FROM itemAttachments JOIN items ON itemAttachments.itemID=items.itemID"
        )
    ),
)
print(
    "ACZG7K8Q:",
    list(c.execute("SELECT itemID, version, itemTypeID FROM items WHERE key='ACZG7K8Q'")),
)
# Simulate upsert annotation bind
print(
    "annotation type:",
    list(c.execute("SELECT itemTypeID FROM itemTypes WHERE typeName='annotation'")),
)
