
#include "allocator.h"
#include "txn.h"
#include <iostream>
#include <chrono>
#include <thread>
#include <vector>
#include <map>
#include <mako.hh>
#include "examples/common.h"
#include "benchmarks/rpc_setup.h"
#include "../src/mako/spinbarrier.h"
#include "../src/mako/benchmarks/mbta_sharded_ordered_index.hh"
#include "benchmarks/sto/Transaction.hh"
#include "benchmarks/sto/multiversion.hh"

using namespace std;
using namespace mako;

class TransactionWorker {
public:
    TransactionWorker(abstract_db *db, int worker_id = 0)
        : db(db), worker_id_(worker_id) {
        txn_obj_buf.reserve(str_arena::MinStrReserveLength);
        txn_obj_buf.resize(db->sizeof_txn_object(0));
    }

    void initialize() {
        scoped_db_thread_ctx ctx(db, false);
        TThread::enable_multiverison();
    }

    void test_ro_fast_path() {
        printf("\n--- Testing Read-Only Fast Path (Replicated) Thread:%ld ---\n", std::this_thread::get_id());

        int home_shard_index = BenchmarkConfig::getInstance().getShardIndex();
        // Only run on the leader for now to verify the fast path logic
        if (!BenchmarkConfig::getInstance().getLeaderConfig()) {
             return;
        }

        mbta_sharded_ordered_index *table = db->open_sharded_index("customer_0");
        
        std::string key = "ro_rep_key_" + std::to_string(worker_id_);
        std::string value_v1 = mako::Encode("val_v1_" + std::to_string(worker_id_));
        std::string value_v2 = mako::Encode("val_v2_" + std::to_string(worker_id_));

        // 1. Write V1
        {
            void *txn = db->new_txn(0, arena, txn_buf());
            try {
                table->put(txn, key, value_v1);
                db->commit_txn(txn);
                printf("[Worker %d] Wrote V1\n", worker_id_);
            } catch (abstract_db::abstract_abort_exception &ex) {
                db->abort_txn(txn);
                printf("[Worker %d] Write V1 Aborted\n", worker_id_);
                return;
            }
        }

        // Wait for replication/stabilization
        // In a real test we might want to poll or wait for a specific condition, but sleep is simple
        std::this_thread::sleep_for(std::chrono::seconds(2));

        // 2. Read V1 with RO Fast Path
        {
            uint64_t flags = transaction_base::TXN_FLAG_READ_ONLY;
            void *txn = db->new_txn(flags, arena, txn_buf());
            std::string read_value;
            try {
                bool found = table->get(txn, key, read_value);
                db->commit_txn(txn); // No-op for RO but good practice
                
                if (found && read_value.find("val_v1_") != std::string::npos) {
                    printf("[Worker %d] RO Read V1: SUCCESS\n", worker_id_);
                } else {
                    printf("[Worker %d] RO Read V1: FAILED (Found=%d, Val=%s)\n", worker_id_, found, read_value.c_str());
                }
            } catch (abstract_db::abstract_abort_exception &ex) {
                db->abort_txn(txn);
                printf("[Worker %d] RO Read V1 Aborted\n", worker_id_);
            }
        }

        // 3. Write V2
        {
            void *txn = db->new_txn(0, arena, txn_buf());
            try {
                table->put(txn, key, value_v2);
                db->commit_txn(txn);
                printf("[Worker %d] Wrote V2\n", worker_id_);
            } catch (abstract_db::abstract_abort_exception &ex) {
                db->abort_txn(txn);
                printf("[Worker %d] Write V2 Aborted\n", worker_id_);
                return;
            }
        }

        std::this_thread::sleep_for(std::chrono::seconds(2));

        // 4. Read V2 with RO Fast Path
        {
            uint64_t flags = transaction_base::TXN_FLAG_READ_ONLY;
            void *txn = db->new_txn(flags, arena, txn_buf());
            std::string read_value;
            try {
                bool found = table->get(txn, key, read_value);
                db->commit_txn(txn);
                
                if (found && read_value.find("val_v2_") != std::string::npos) {
                    printf("[Worker %d] RO Read V2: SUCCESS\n", worker_id_);
                } else {
                    printf("[Worker %d] RO Read V2: FAILED (Found=%d, Val=%s)\n", worker_id_, found, read_value.c_str());
                }
            } catch (abstract_db::abstract_abort_exception &ex) {
                db->abort_txn(txn);
                printf("[Worker %d] RO Read V2 Aborted\n", worker_id_);
            }
        }
    }

protected:
    abstract_db *const db;
    int worker_id_;
    str_arena arena;
    std::string txn_obj_buf;
    inline void *txn_buf() { return (void *)txn_obj_buf.data(); }
};

void run_worker_tests(abstract_db *db, int worker_id,
                      spin_barrier *barrier_ready,
                      spin_barrier *barrier_start) {
    auto worker = new TransactionWorker(db, worker_id);
    worker->initialize();

    barrier_ready->count_down();
    barrier_start->wait_for();

    worker->test_ro_fast_path();

    printf("[Worker %d] Completed\n", worker_id);
    delete worker;
}

void run_tests(abstract_db* db) {
    size_t nthreads = BenchmarkConfig::getInstance().getNthreads();
    std::vector<std::thread> worker_threads;
    worker_threads.reserve(nthreads);
    spin_barrier barrier_ready(nthreads);
    spin_barrier barrier_start(1);

    for (size_t i = 0; i < nthreads; ++i) {
        worker_threads.emplace_back(run_worker_tests, db, i,
                                    &barrier_ready, &barrier_start);
    }

    barrier_ready.wait_for();
    barrier_start.count_down();

    for (auto& t : worker_threads) {
        t.join();
    }
}

int main(int argc, char **argv) {
    if (argc != 6) {
        printf("Usage: %s <nshards> <shardIdx> <nthreads> <paxos_proc_name> <is_replicated>\n", argv[0]);
        return 1;
    }

    int nshards = std::stoi(argv[1]);
    int shardIdx = std::stoi(argv[2]);
    int nthreads = std::stoi(argv[3]);
    std::string paxos_proc_name = std::string(argv[4]);
    int is_replicated = std::stoi(argv[5]);

    std::string config_path = get_current_absolute_path() 
            + "../src/mako/config/local-shards" + std::to_string(nshards) 
            + "-warehouses" + std::to_string(nthreads) + ".yml";
    vector<string> paxos_config_file{
        get_current_absolute_path() + "../config/1leader_2followers/paxos" + std::to_string(nthreads) + "_shardidx" + std::to_string(shardIdx) + ".yml",
        get_current_absolute_path() + "../config/occ_paxos.yml"
    };
    
    auto& benchConfig = BenchmarkConfig::getInstance();
    benchConfig.setNshards(nshards);
    benchConfig.setShardIndex(shardIdx);
    benchConfig.setNthreads(nthreads);
    benchConfig.setPaxosProcName(paxos_proc_name);
    benchConfig.setIsReplicated(is_replicated);

    auto config = new transport::Configuration(config_path);
    benchConfig.setConfig(config);
    benchConfig.setPaxosConfigFile(paxos_config_file);

    init_env();

    printf("=== Mako RO Fast Path Test (Replicated) ===\n");
    
    abstract_db* db = initWithDB();

    if (benchConfig.getLeaderConfig()) {
        mako::setup_erpc_server();
        mbta_sharded_ordered_index *table = db->open_sharded_index("customer_0");

        map<int, abstract_ordered_index*> open_tables;
        auto *local_table = table->shard_for_index(benchConfig.getShardIndex());
        if (local_table) {
            open_tables[local_table->get_table_id()] = local_table;
        }
        mako::setup_helper(db, std::ref(open_tables));

        std::this_thread::sleep_for(std::chrono::seconds(5));
    }

    if (benchConfig.getLeaderConfig()) {
        run_tests(db);
    } else {
        // Followers just wait
        std::this_thread::sleep_for(std::chrono::seconds(20));
    }

    std::this_thread::sleep_for(std::chrono::seconds(5));

    if (benchConfig.getLeaderConfig()) {
        mako::stop_helper();
        mako::stop_erpc_server();
    }

    db_close();
    return 0;
}
