masstree_btree.h - Already has insert implementation that stores old value in passed pointer
Probably from the Masstree implementation
AFAIK, this feature of saving the old value is not used anywhere

txn.h (line 643) defines is_snapshot = flag showing if the transaction is a read-only transaction
AFAIK, there is no special read treatment for read-only transactions

READ PATH
txn_impl.h (line 567): `do_tuple_read`


Purpose:
Add a read-only transaction fast path to Mako. Whenever a read-only transaction is received, immediately return the result, doing away with the 2PC protocol.
This will lead to relaxed consistency (no serializablity) but snapshot isolation semantics.

Idea:
To store a previous version of the value such that the system's watermark has advanced past it's version and it can be served to a read-only transaction without synchronizing with other servers.

Considerations:
The previous version is currently not stored. It is only present transitively as part of Multi version concurrency control requirements. 

since this is a sharded & geo-replicated database, the transaction would be speculatively executed and won't be committed until it is replicated across a majority of the replicas. This is tracked by the system watermark

In the read path, the transaction should always read from the stable version for a read-only transaction (if stable version is not null) because of the above replication complexity
I only want to change the read mechanism for read-only transactions

Process:

1. Modify commit protocol to update stable version on the value to be committed
2. If the transaction is read-only, do not co-ordinate with other replicas
  - Read stable values from each shard and return (no speculative execution)
  - If stable value is null, read as a regular transaction