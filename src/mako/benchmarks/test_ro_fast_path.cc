
#include "allocator.h"
#include "txn.h"
#include <examples/common.h>
#include "benchmarks/sto/Transaction.hh"
#include "benchmarks/sto/multiversion.hh"
#include <mako.hh>

using namespace std;

class ReadOnlyFastPathTest {
public:
    ReadOnlyFastPathTest(abstract_db *db) : db(db) {
        txn_obj_buf.reserve(str_arena::MinStrReserveLength);
        txn_obj_buf.resize(db->sizeof_txn_object(0));
    }

    void initialize() {
        scoped_db_thread_ctx ctx(db, false);
        TThread::enable_multiverison();
    }

    void test_ro_fast_path() {
        printf("\n--- Testing Read-Only Fast Path ---\n");
        static abstract_ordered_index *table = db->open_index("ro_test_table");
        
        // 1. Insert a record using a normal RW transaction
        string key = "ro_key";
        string value = mako::Encode("ro_value_v1");
        {
            void *txn = db->new_txn(0, arena, txn_buf());
            try {
                table->put(txn, key, value);
                if (db->commit_txn(txn)) {
                    printf("Insert committed.\n");
                } else {
                    printf("Insert failed to commit.\n");
                    db->abort_txn(txn);
                    return;
                }
            } catch (...) {
                db->abort_txn(txn);
                printf("Insert aborted exception.\n");
                return;
            }
        }

        // Advance epoch/watermark to ensure the version is stable
        // In a real system, this happens asynchronously. Here we might need to wait or force it.
        // For the purpose of this test, we assume the single-node setup updates watermark quickly.
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        // 2. Read the record using a Read-Only transaction
        {
            // Set TXN_FLAG_READ_ONLY
            uint64_t flags = transaction_base::TXN_FLAG_READ_ONLY;
            // Hint is optional but good practice
            abstract_db::TxnProfileHint hint = abstract_db::HINT_DEFAULT; 
            
            void *txn = db->new_txn(flags, arena, txn_buf(), hint);
            
            // Verify snapshot ID is set (we can't easily access private members, but we can verify behavior)
            // If the fast path works, we should get the value.
            
            string read_value;
            try {
                bool found = table->get(txn, key, read_value);
                if (found) {
                     string decoded_value;
                     // const char* ptr = read_value.data(); // Unused variable
                     // Assuming simple encoding/decoding or just string comparison if Encode does nothing complex
                     // mako::Encode usually prepends size or something.
                     // Let's just check if it contains our string.
                     if (read_value.find("ro_value_v1") != string::npos) {
                         printf("Read-Only Fast Path: SUCCESS (Value matched)\n");
                     } else {
                         printf("Read-Only Fast Path: FAILURE (Value mismatch: %s)\n", read_value.c_str());
                     }
                } else {
                    printf("Read-Only Fast Path: FAILURE (Key not found)\n");
                }
                
                // Commit is a no-op for RO fast path usually, but good to call
                db->commit_txn(txn);
                
            } catch (...) {
                db->abort_txn(txn);
                printf("Read-Only Fast Path: FAILURE (Exception)\n");
            }
        }
        
        // 3. Update the record
        string value_v2 = mako::Encode("ro_value_v2");
        {
             void *txn = db->new_txn(0, arena, txn_buf());
            try {
                table->put(txn, key, value_v2);
                db->commit_txn(txn);
                printf("Update committed.\n");
            } catch (...) {
                db->abort_txn(txn);
            }
        }
        
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        // 4. Read again with RO transaction
        {
            uint64_t flags = transaction_base::TXN_FLAG_READ_ONLY;
            void *txn = db->new_txn(flags, arena, txn_buf());
            string read_value;
            try {
                bool found = table->get(txn, key, read_value);
                if (found && read_value.find("ro_value_v2") != string::npos) {
                     printf("Read-Only Fast Path (v2): SUCCESS\n");
                } else {
                     printf("Read-Only Fast Path (v2): FAILURE\n");
                }
                db->commit_txn(txn);
            } catch (...) {
                db->abort_txn(txn);
            }
        }
    }

protected:
    abstract_db *const db;
    str_arena arena;
    std::string txn_obj_buf;
    inline void *txn_buf() { return (void *)txn_obj_buf.data(); }
};

int main() {
    abstract_db *db = new mbta_wrapper;
    db->init();
    
    // Setup minimal config
    auto config = new transport::Configuration("/home/nimit/mako/config/mako_single_node.yml");
    config->nshards = 1;
    BenchmarkConfig::getInstance().setConfig(config);

    auto test = new ReadOnlyFastPathTest(db);
    test->initialize();
    test->test_ro_fast_path();
    
    delete test;
    delete db;
    return 0;
}
