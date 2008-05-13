import tempfile, os, os.path, subprocess, md5, time, sys, random, threading
import ringogw

home_dir = tempfile.mkdtemp("", "ringotest-") + '/'
node_id = 0
conn = None

os.environ['RESYNC_INTERVAL'] = '10000'
os.environ['CHECK_EXT_INTERVAL'] = '10000'


def new_node(id = None):
        global node_id
        if id == None:
                id = md5.md5("test-%d" % node_id).hexdigest()
                node_id += 1
        path = home_dir + id
        if not os.path.exists(path):
                os.mkdir(path)
        p = subprocess.Popen(["start_ringo.sh", path],
                stdin = subprocess.PIPE, stdout = subprocess.PIPE,
                        stderr = subprocess.PIPE, env = os.environ)
        return id, p

def kill_node(id):
        subprocess.call(["pkill", "-f", id])

def domain_id(name, chunk):
        return md5.md5("%d %s" % (chunk, name)).hexdigest().upper()

def make_domain_id(did):
        return hex(did)[2:-1]

def check_entries(r, nrepl, nentries):
        if r[0] != 200:
                return False
        if len(r[1][3]) != nrepl:
                return False

        owner_root = -2
        roots = []
        for node in r[1][3]:
                num = node["num_entries"]
                if num == "undefined" or int(num) != nentries:
                        return False
                root = -1
                if "synctree_root" in node:
                        root = node["synctree_root"][0][1]
                        roots.append(root)
                if node["owner"]:
                        owner_root = root

        if len(roots) != nrepl:
                return False

        # check that root hashes match
        return [r for r in roots if r != owner_root] == []

def _check_results(reply, num):
        if reply[0] != 200:
                return False
        nodes = reply[1]
        l = len([node for node in nodes if node['ok']])
        return len(nodes) == l == num

def _test_ring(n, num = None, nodeids = []):
        if num == None:
                check = lambda x: _check_results(x, n)
        else:
                check = lambda x: _check_results(x, num)

        if nodeids:
                n = len(nodeids)

        print "Launching nodes",
        res = []
        for i in range(n):
                time.sleep(1)
                if nodeids:
                        res.append(new_node(nodeids[i]))
                else:
                        res.append(new_node())
                sys.stdout.write(".")
        print
        t = time.time()
        if _wait_until("/mon/ring/nodes", check, 30):
                print "Ring converged in %d seconds" % (time.time() - t)
                return True
        return False

def _wait_until(req, check, timeout):
        print "Checking results",
        for i in range(timeout):
                time.sleep(1)
                r = ringogw.request(req)
                if check(r):
                        print
                        return True
                sys.stdout.write(".")
        print
        return False

def _put_entries(name, nitems, retries = 0):
        t = time.time()
        for i in range(nitems):
                ringogw.put(name, "item-%d" % i, "testitem-%d" % i,
                        retries = retries)
        print "%d items put in %dms" % (nitems, (time.time() - t) * 1000)

def _test_repl(name, n, nrepl, nitems, create_ring = True):
        if create_ring and not _test_ring(n):
                return False
        node, domainid = ringogw.create(name, nrepl)
        _put_entries(name, nitems)
        return _wait_until("/mon/domains/domain?id=0x" + domainid,
                lambda x: check_entries(x, n, nitems), 50)

def _check_extfiles(node, domainid, num):
        files = os.listdir("%s/%s/rdomain-%s/" % (home_dir, node, domainid))
        return len([f for f in files if f.startswith("value")]) == num

def _cache_test(**kwargs):
        def check_values(key, ret):
                for i, v in enumerate(ret):
                        if v != key + "-pie-%d" % i:
                                raise "Invalid results: Key <%s>: %s"\
                                        % (key, r)

        if not _test_ring(1):
                return False
        
        node, domainid = ringogw.create("cachetest", 5, **kwargs)
        print "Putting 100500 items.."
        t = time.time()
        head = []
        tail = []
        for i in range(105):
                key = "head-%d" % i
                head.append(key)
                for j in range(100):
                        ringogw.put("cachetest", key, key + "-pie-%d" % j)
        for i in range(50500):
                key = "tail-%d" % i
                tail.append(key)
                ringogw.put("cachetest", key, key + "-pie-0")

        print "items put in %dms" % ((time.time() - t) * 1000)

        print "Retrieving all keys and checking values.."
        t = time.time()
        for key in head + tail:
                check_values(key, ringogw.get("cachetest", key))
        print "Get took %dms" % ((time.time() - t) * 1000)
        
        print "Getting 10000 keys in sequential order"
        s = random.sample(head, 100) + random.sample(tail, 10)
        t = time.time()
        for i in range(10):
                random.shuffle(s)
                for key in s:
                        for j in range(10):
                                check_values(key, ringogw.get("cachetest", key))
        print "Get took %dms" % ((time.time() - t) * 1000)

        print "Getting 10000 keys in random order"
        t = time.time()
        for i in range(10000):
                key = random.choice(tail)
                check_values(key, ringogw.get("cachetest", key))
        print "Get took %dms" % ((time.time() - t) * 1000)
        return True

# make a ring, check that converges
def test01_ring10():
        return _test_ring(10)

# make a large ring, check that converges
def test02_ring100():
        return _test_ring(100)

# make a ring in two phases, check that converges
def test03_ring_newnodes():
        print "Launching first batch of nodes"
        if not _test_ring(10):
                return False
        time.sleep(10)
        print "Launching second batch of nodes"
        return _test_ring(10, 20)

# make a ring, kill random nodes, check that heals
def test04_ring_randomkill():
        res = []
        print "Launching nodes",
        for i in range(50):
                time.sleep(1)
                id, proc = new_node()
                res.append(id)
                sys.stdout.write(".")
        print
        time.sleep(10)
        for id in random.sample(res, 23):
                print "Kill", id
                kill_node(id)
        t = time.time()
        if _wait_until("/mon/ring/nodes", 
                        lambda x: _check_results(x, 27), 60):
                print "Ring healed in %d seconds" % (time.time() - t)
                return True
        return False


# create, put, check that succeeds
def test05_replication1():
        return _test_repl("test_replication1", 1, 1, 100)

# create, put, check that succeeds, replicates
def test06_replication50():
        return _test_repl("test_replication50", 50, 50, 100)

# create, put, add new node (replica), check that resyncs ok
def test07_addreplica(first_owner = True):
        if first_owner:
                name = "addreplicas_test"
        else:
                name = "addowner_test"
        check1 = lambda x: _check_results(x, 1)
        check2 = lambda x: _check_results(x, 2)
        did = domain_id(name, 0)
        # a node id that is guaranteed to become owner for the domain
        owner_id = real_owner = make_domain_id(int(did, 16) - 1)
        # a node id that is guaranteed to become replica for the domain
        repl_id = make_domain_id(int(did, 16) + 1)
        
        if not first_owner:
                tmp = repl_id
                repl_id = owner_id
                owner_id = tmp

        new_node(owner_id)
        print "Waiting for ring to converge:"
        if not _wait_until("/mon/ring/nodes", check1, 30):
                print "Ring didn't converge"
                return False
        print "Creating and populating the domain:"
        if not _test_repl(name, 1, 2, 50, False):
                print "Couldn't create and populate the domain"
                return False
        
        if first_owner:
                print "Adding a new replica:"
        else:
                print "Adding a new owner:"

        new_node(repl_id)
        if not _wait_until("/mon/ring/nodes", check2, 30):
                print "Ring didn't converge"
                return False
       
        _put_entries(name, 50)

        print "Waiting for resync (timeout 300s, be patient):"
        if not _wait_until("/mon/domains/domain?id=0x" + did,
                lambda x: check_entries(x, 2, 100), 300):
                print "Resync didn't finish in time"
                return False
        
        re = ringogw.request("/mon/domains/domain?id=0x" + did)
        repl = re[1][3]
        
        if real_owner in [r['node'] for r in repl if r['owner']][0]:
                print "Owner matches"
                return True
        else:
                print "Invalid owner for domain %s (should be %s), got: %s" %\
                        (did, owner_id, repl)
                return False

# create, put, add new node (owner), check that resyncs ok and owner is
# transferred correctly
def test08_addowner():
        return test07_addreplica(False)


# create, put, kill owner, put, reincarnate owner, check that succeeds 
# and resyncs 
def test09_killowner():
        if not _test_ring(10):
                return False

        print "Create and populate domain"
        node, domainid = ringogw.create("killowner", 5)
        _put_entries("killowner", 50)
        
        kill_id = node.split('@')[0].split("-")[1]
        print "Kill owner", kill_id
        kill_node(kill_id)
       
        print "Put 50 entries:"
        _put_entries("killowner", 50, retries = 10)
        if not _wait_until("/mon/domains/domain?id=0x" + domainid,
                        lambda x: check_entries(x, 6, 100), 300):
                print "Resync didn't finish in time"
                return False
       
        print "Owner reincarnates"
        new_node(kill_id)
        
        print "Put 50 entries:"
        _put_entries("killowner", 50, retries = 10)
        
        if _wait_until("/mon/domains/domain?id=0x" + domainid,
                        lambda x: check_entries(x, 7, 150), 300):
                return True
        else:
                print "Resync didn't finish in time"
                return False

# create owner and a replica that has a distant id. Put items. Kill owner,
# add items to the distant node. Reincarnate owner and add new nodes between
# the owner and the distant node. Check that resyncs ok. 
#
# NB: This test doesn't quite test what it should: Polling status from the 
# distant node activates it, which causes resync to active as well. In a more
# realistic case the owner would have to active the distant node by itself with
# the global resync process.
def test10_distantsync():
        did = domain_id("distantsync", 0)

        distant_id, p = new_node(make_domain_id(int(did, 16) - 20))
        time.sleep(1)
        owner_id, p = new_node(did)

        print "Owner is", owner_id
        print "Distant node is", distant_id
        if not _wait_until("/mon/ring/nodes",
                        lambda x: _check_results(x, 2), 30):
                print "Ring didn't converge"
                return False

        print "Create and populate domain"
        if not _test_repl("distantsync", 2, 3, 60, create_ring = False):
                print "Couldn't create and populate the domain"
                return False
                
        print "Kill owner", owner_id
        kill_node(owner_id)
        
        print "Put 30 entries:"
        _put_entries("distantsync", 30, retries = 10)

        print "Creating more node, reincarnating owner"
        if not _test_ring(0, 40, [make_domain_id(int(did, 16) + i)
                        for i in range(-19, 20)]):
                return False
        
        print "Putting 10 entries to the new owner"
        _put_entries("distantsync", 10)

        print "Waiting for everything to resync"
        if _wait_until("/mon/domains/domain?id=0x" + did,
                        lambda x: check_entries(x, 5, 100), 300):
                return True
        else:
                print "Resync didn't finish in time"
                return False

# This test checks that code updates can be perfomed smoothly in the
# ring. This happens by restarting nodes one by one. Restarting shouldn't
# distrupt concurrent put operations, except some re-requests may be
# needed.
def test11_simcodeupdate():
        names = ["simcodeupdate1", "simcodeupdate2"]
        def pput():
                for i in range(10):
                        k = "item-%d" % i
                        v = "testitem-%d" % i
                        for name in names:
                                ringogw.put(name, k, v, retries = 10)
                                        
        did1 = int(domain_id(names[0], 0), 16)
        did2 = int(domain_id(names[1], 0), 16)
        mi = min(did1, did2)
        ids = [make_domain_id(mi + i) for i in range(10)]
        
        if not _test_ring(0, 10, ids):
                return False
        
        print "Creating domains.."

        for name in names:
                ringogw.create(name, 6)

        print "Restarting nodes one at time:"
        for id in ids:
                print "Restart", id
                t = threading.Thread(target = pput).start()
                kill_node(id)
                new_node(id)
                # if the pause is too small, say 1sec, there's a danger
                # that replicas aren't yet fully propagated for the previous
                # requests and killing a node might make a replica jump over
                # the zombie and make a new replica domain. In the extreme
                # case the domain is propagated to all the nodes in the ring.
                time.sleep(7)
        
        print "All the nodes restarted."
        print "NB: Test may sometimes fail due to a wrong number of replicas,"
        print "typically 7 instead of 8. This is ok."

        # actually the number of replicas may be off by one here, if a put
        # requests hits a node while its down. So don't worry if the test fails
        # due to a wrong number of replicas.
        if not _wait_until("/mon/domains/domain?id=0x" + make_domain_id(did1),
                        lambda x: check_entries(x, 8, 100), 300):
                return False
        if not _wait_until("/mon/domains/domain?id=0x" + make_domain_id(did2),
                        lambda x: check_entries(x, 8, 100), 300):
                return False
        return True

# Check that putting large (1M) entries to external files works in
# replication and resyncing.
def test12_extsync():
        if not _test_ring(5):
                return False
        
        node, domainid = ringogw.create("extsync", 6)
                
        v = "!" * 1024**2
        print "Putting ten 1M values"
        for i in range(10):
                ringogw.put("extsync", "fub-%d" % i, v, verbose = True)
        if not _wait_until("/mon/domains/domain?id=0x" + domainid,
                        lambda x: x[0] == 200, 30):
                return False
        
        replicas = [n['node'].split('-')[1].split('@')[0] for n in\
                ringogw.request("/mon/domains/domain?id=0x" + domainid)[1][3]]

        for repl in replicas:
                if not _check_extfiles(repl, domainid, 10):
                        print "Ext files not found on node", repl
                        return False
        print "Ext files written ok to all replicas"

        print "Deleting some files on node", replicas[0]
        print "to check that check_external works:" 
        files = os.listdir("%s/%s/rdomain-%s/" %
                        (home_dir, replicas[0], domainid))
        for rem in random.sample(
                        [f for f in files if f.startswith("value")], 5):
                print "Deleting", rem
                os.remove("%s/%s/rdomain-%s/%s" %
                        (home_dir, replicas[0], domainid, rem))
        
        newid, p = new_node()
        print "Creating a new node", newid
        print "Putting an extra item (should go to the new node as well)"
        ringogw.put("extsync", "extra", v, verbose = True)

        if not _wait_until("/mon/domains/domain?id=0x" + domainid,
                        lambda x: check_entries(x, 6, 11), 300):
                return False
        
        for repl in replicas + [newid]:
                if not _check_extfiles(newid, domainid, 11):
                        print "All ext files not found on node", repl 
                        return False
        return True

def test13_singleget():
        if not _test_ring(1):
                return False
        
        node, domainid = ringogw.create("basicget", 5)        
        for i in range(5):
                ringogw.put("basicget", "muppet-%d" % i, "nufnuf-%d" % i)

        for i in range(5):
                r = ringogw.get("basicget", "muppet-%d" % i, single = True)
                if r != "nufnuf-%d" % i:
                        print "Invalid reply", r
                        return False
        return True

def test14_multiget():
        def check_reply(entry, out):
                if entry != "nufnuf-%d" % len(out): 
                        raise "Invalid reply", entry
                out.append(entry)

        if not _test_ring(1):
                return False
        
        node, domainid = ringogw.create("multiget", 5)
        print "Putting 1000 items.."
        for i in range(1000):
                ringogw.put("multiget", "bork", "nufnuf-%d" % i)
        
        print "Getting 1000 items.."
        out = ringogw.get("multiget", "bork", entry_callback = check_reply, verbose = True)
        if len(out) != 1000:
                raise "Invalid number of replies: %d" % len(out)
        return True

        

def test15_iblockcache():
        return _cache_test()
        
def test16_keycache():
        return _cache_test(keycache = True)

def test17_putget(**kwargs):

        keycache = 'keycache' in kwargs
        if keycache:
                print "Testing with key cache"
        else:
                print "Testing with iblock cache"
                if not _test_ring(5):
                        return False
        
        dname = "putgettest-%s" % keycache
        node, domainid = ringogw.create(dname, 5, **kwargs)
        values = ["zing-%d-%s" % (i, keycache) for i in range(2)]

        print "Putting 15050 keys.."

        for i in range(1505):
                key = "k-%d-%s" % (i, keycache)
                for j in range(10):
                        for value in values:
                                r = ringogw.put(dname, key, value)        
                        r = ringogw.get(dname, key) 
                        if r != values * (j + 1):
                                raise "Invalid reply %s expected %s" %\
                                        (r, values * (j + 1))
        print "Results ok"

        if keycache:
                return True
        else:
                return test17_putget(keycache = True)

def test18_regeniblocks():
        N = 50500
        def check_get():
                for i in range(N):
                        r = ringogw.get("regentest", "abc-%d" % i)
                        if r != ['def-%d' % i]:
                                raise "Invalid reply to key %s: %s" %\
                                        ("abc-%d" % i, r)
        if not _test_ring(1):
                return False
        node, domainid = ringogw.create("regentest", 5)
        print "Putting %d entries.." % N
        for i in range(N):
                ringogw.put("regentest", "abc-%d" % i, "def-%d" % i)
        print "Entries put"
        check_get()
        print "Get ok"

        kill_id = node.split('@')[0].split("-")[1]
        print "Kill owner", kill_id
        kill_node(kill_id)

        path = "%s/%s/rdomain-%s/" % (home_dir, kill_id, domainid)
        ifiles = sorted([(int(x.split('-')[1]), x)\
                        for x in os.listdir(path) if x.startswith("iblock")])
        if len(ifiles) != N / 10000:
                print "Incorrect number of iblocks: %d expected %d"\
                        % (len(ifiles), N / 10000)
                print "iblocks", ifiles
                return False
        iblocks = [] 
        print "Removing some iblocks"
        for i, iblock in enumerate(ifiles):
                fname = "%s/%s" % (path, iblock[1])
                f = file(fname).read()
                iblocks.append((iblock[1], md5.md5(f).hexdigest()))
                if i % 2:
                        print "Deleting", iblock[1]
                        os.remove(fname)
        
        print "Reincarnating owner"
        new_node(kill_id)
        if not _wait_until("/mon/ring/nodes",
                        lambda x: _check_results(x, 1), 60):
                return False
        print "Check get.."
        check_get()
        print "Get ok"
        print "Checking iblocks"
        for iblock, checksum in iblocks:
                fname = "%s/%s" % (path, iblock)
                f = file(fname).read()
                if checksum != md5.md5(f).hexdigest():
                        print "Checksums don't match for iblock", iblock
                        return False
        print "Checksums match"
        return True

# 1. test that iblocks are re-generated ok: Put N iblocks, delete K iblocks, 
#    check that re-generated iblocks are identical
# 2. redirected get, new owner, check that get succeeds

        
# 7. (100 domains) create N domains, put entries, killing random domains at the
#        same time, check that all entries available in the end

tests = sorted([f for f in globals().keys() if f.startswith("test")])

if len(sys.argv) > 2 and sys.argv[2] == '?':
        print "Available tests:\n", "\n".join([t[7:] for t in tests])
        sys.exit(1)

ringogw.sethost(sys.argv[1])
for f in tests:
        prefix, testname = f.split("_", 1)
        if len(sys.argv) > 2 and testname not in sys.argv[2:]:
                continue
        kill_node("ringotest")
        ringogw.request("/mon/ring/reset")
        ringogw.request("/mon/domains/reset")
        time.sleep(1)
        print "*** Starting", testname
        if globals()[f]():
                print "+++ Test", testname, "successful"
        else:
                print "--- Test", testname, "failed"
                sys.exit(1)






