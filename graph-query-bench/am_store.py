# In-memory source-type adjacency matrix.
# { source_id: { node_type: [target_id, ...] } }
# Module-level dict is a singleton within the process — persists across
# walker calls without any file I/O. Volatile across server restarts.
am_index: dict = {}


def get_type_mro(obj) -> list:
    """Return Jac-relevant type names from obj's MRO.

    Walks type(obj).__mro__ and collects class names until it hits a class
    whose module starts with 'jaclang' (internal runtime base) or a Python
    builtin. This gives the full chain of user-defined Jac node types,
    enabling Option-A inheritance indexing: index each node under every
    ancestor type so that a query for a parent type returns all subclass nodes.

    Example:
        node Animal {}
        node Dog :Animal: {}

        get_type_mro(Dog())  →  ["Dog", "Animal"]

        Index entry:
            am_index[source]["Dog"]    = [dog_id]
            am_index[source]["Animal"] = [dog_id]   ← inherited bucket

        Query (?:Animal) looks up "Animal" bucket → correctly returns Dog nodes.
    """
    result = []
    for cls in type(obj).__mro__:
        mod = getattr(cls, "__module__", "") or ""
        if mod.startswith("jaclang") or cls.__name__ == "object":
            break
        result.append(cls.__name__)
    return result
