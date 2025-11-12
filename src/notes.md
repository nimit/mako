masstree_btree.h - Already has insert implementation that stores old value in passed pointer
Probably from the Masstree implementation
AFAIK, the old value is not stored anywhere

txn.h (line 643) defines is_snapshot = flag showing if the transaction is a read-only transaction
AFAIK, there is no special read treatment for read-only transactions

READ PATH
txn_impl.h (line 567): `do_tuple_read`
