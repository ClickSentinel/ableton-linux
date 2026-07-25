/* linkprobe.c: Wine-side Ableton Link multicast verdict (PE, CRT-free).
 *
 * usage:  run_in_prefix.sh linkprobe.exe     (or: wine tools/linkprobe.exe)
 * Joins the Ableton Link discovery group 224.76.78.75:20808 per local IPv4
 * interface (SO_REUSEADDR bind, one IP_ADD_MEMBERSHIP per interface, like
 * the Ableton Link SDK), sends five "_asdp_v1" kAlive datagrams 250 ms
 * apart on each joined interface, then listens ~6 s for discovery traffic.
 * Prints verdict lines LINKPROBE TX / RX-LOOPBACK / RX-NETWORK / PEERS and
 * exits 0 iff TX OK and RX-LOOPBACK OK, i.e. Wine's multicast stack works.
 * build:  tools/build_linkprobe.sh (real PE via clang, wine headers, no CRT)
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#define LINK_GROUP  "224.76.78.75"
#define LINK_PORT   20808
#define TX_COUNT    5
#define TX_GAP_MS   250
#define LISTEN_MS   6000    /* RX window, starts after the TX burst */
#define MAX_PEERS   64
#define MAX_LOCAL   16

static HANDLE g_out;
static char buf[512];

static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

/* no CRT: the few helpers needed, spelled out */
static void zero( void *p, int n ){ char *c = (char *)p; while (n-- > 0) *c++ = 0; }

static int eq8( const unsigned char *a, const unsigned char *b )
{
    int i;
    for (i = 0; i < 8; i++) if (a[i] != b[i]) return 0;
    return 1;
}

static int has_magic( const unsigned char *p )   /* "_asdp_v\x01" */
{
    /* the 8th magic byte is the protocol version BYTE 0x01, not ASCII '1'
     * (0x31): kProtocolHeader in the SDK's discovery/v1/Messages.hpp */
    static const unsigned char m[8] = { '_','a','s','d','p','_','v',1 };
    return eq8( p, m );
}

/* append addr to list, skipping duplicates and 0.0.0.0 */
static void add_local( unsigned long *list, int *n, int max, unsigned long addr )
{
    int i;
    if (!addr) return;
    for (i = 0; i < *n; i++) if (list[i] == addr) return;
    if (*n < max) list[(*n)++] = addr;
}

/* xorshift64 for a pseudo-random self nodeId */
static unsigned long long rng_state;
static unsigned long long rng_next( void )
{
    unsigned long long x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return rng_state = x;
}

int mainCRTStartup( void )
{
    WSADATA wsa;
    SOCKET s = INVALID_SOCKET;
    struct sockaddr_in bind_addr, dest, from;
    struct ip_mreq mreq;
    int one = 1, ttl = 4, i, k, fl;
    int tx_err = 0, rx_total = 0, rx_magic = 0, rx_self = 0, rx_network = 0;
    unsigned char self_id[8], alive[20], pkt[512];
    unsigned char peers[MAX_PEERS][8];
    int npeers = 0;
    unsigned long local[MAX_LOCAL];
    int nlocal = 0;
    unsigned long joined[MAX_LOCAL];
    int njoined = 0, join_fail = 0;
    DWORD deadline;

    g_out = GetStdHandle( STD_OUTPUT_HANDLE );

    if (WSAStartup( MAKEWORD( 2, 2 ), &wsa )) { P( "WSAStartup failed\r\n" ); return 1; }

    s = socket( AF_INET, SOCK_DGRAM, IPPROTO_UDP );
    if (s == INVALID_SOCKET) { P( "socket failed: %d\r\n", WSAGetLastError() ); return 1; }

    if (setsockopt( s, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof(one) ))
        P( "warning: SO_REUSEADDR failed: %d\r\n", WSAGetLastError() );

    zero( &bind_addr, sizeof(bind_addr) );
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons( LINK_PORT );
    bind_addr.sin_addr.s_addr = 0;   /* INADDR_ANY */
    if (bind( s, (struct sockaddr *)&bind_addr, sizeof(bind_addr) ))
    {
        P( "bind 0.0.0.0:%d failed: %d\r\n", LINK_PORT, WSAGetLastError() );
        closesocket( s ); WSACleanup();
        return 1;
    }

    if (setsockopt( s, IPPROTO_IP, IP_MULTICAST_TTL, (const char *)&ttl, sizeof(ttl) ))
        P( "warning: IP_MULTICAST_TTL failed: %d\r\n", WSAGetLastError() );
    if (setsockopt( s, IPPROTO_IP, IP_MULTICAST_LOOP, (const char *)&one, sizeof(one) ))
        P( "warning: IP_MULTICAST_LOOP failed: %d\r\n", WSAGetLastError() );

    /* pseudo-random 8-byte self nodeId */
    rng_state = (unsigned long long)GetTickCount()
              ^ ((unsigned long long)GetCurrentProcessId() << 20)
              ^ ((unsigned long long)(UINT_PTR)&wsa << 32);
    if (!rng_state) rng_state = 0x9e3779b97f4a7c15ULL;
    for (i = 0; i < 8; i++) self_id[i] = (unsigned char)rng_next();

    /* minimal valid _asdp_v1 kAlive datagram, 20 bytes:
     * magic[8] | msgType=1 | ttl=1 | groupId=0 | nodeId[8]
     * (magic byte 7 is version BYTE 0x01, not ASCII '1'; see has_magic) */
    {
        static const unsigned char m[8] = { '_','a','s','d','p','_','v',1 };
        for (i = 0; i < 8; i++) alive[i] = m[i];
    }
    alive[8] = 1;    /* msgType kAlive */
    alive[9] = 1;    /* ttl */
    alive[10] = 0;   /* groupId (u16, 0) */
    alive[11] = 0;
    for (i = 0; i < 8; i++) alive[12 + i] = self_id[i];

    /* local IPv4 addresses, used BOTH as per-interface join targets and for
     * network-RX discrimination. Sources: 127.0.0.0/8, the interface list
     * (SIO_ADDRESS_LIST_QUERY, the Winsock equivalent of the per-interface
     * enumeration the Ableton Link SDK does via GetAdaptersAddresses), the
     * primary interface address (UDP connect trick), and whatever the
     * hostname resolves to. An INADDR_ANY join instead follows the
     * 224.0.0.0/4 route, which can land the membership on the wrong
     * interface entirely (e.g. lo), never meeting peers on the LAN. */
    add_local( local, &nlocal, MAX_LOCAL, htonl( 0x7f000001UL ) );
    {
        unsigned char listbuf[2048];
        DWORD ret_size = 0;
        SOCKET_ADDRESS_LIST *sal = (SOCKET_ADDRESS_LIST *)listbuf;
        if (!WSAIoctl( s, SIO_ADDRESS_LIST_QUERY, NULL, 0,
                       listbuf, sizeof(listbuf), &ret_size, NULL, NULL ))
        {
            for (k = 0; k < sal->iAddressCount; k++)
            {
                struct sockaddr_in *sa = (struct sockaddr_in *)sal->Address[k].lpSockaddr;
                if (sa && sa->sin_family == AF_INET)
                    add_local( local, &nlocal, MAX_LOCAL, sa->sin_addr.s_addr );
            }
        }
        else
            P( "warning: SIO_ADDRESS_LIST_QUERY failed: %d\r\n", WSAGetLastError() );
    }
    {
        SOCKET t = socket( AF_INET, SOCK_DGRAM, IPPROTO_UDP );
        if (t != INVALID_SOCKET)
        {
            zero( &from, sizeof(from) );
            from.sin_family = AF_INET;
            from.sin_port = htons( LINK_PORT );
            from.sin_addr.s_addr = inet_addr( LINK_GROUP );
            if (!connect( t, (struct sockaddr *)&from, sizeof(from) ))
            {
                struct sockaddr_in me;
                int ml = sizeof(me);
                zero( &me, sizeof(me) );
                if (!getsockname( t, (struct sockaddr *)&me, &ml ))
                    add_local( local, &nlocal, MAX_LOCAL, me.sin_addr.s_addr );
            }
            closesocket( t );
        }
    }
    {
        char hn[256];
        zero( hn, sizeof(hn) );
        if (!gethostname( hn, sizeof(hn) - 1 ))
        {
            struct hostent *he = gethostbyname( hn );
            if (he)
                for (k = 0; he->h_addr_list[k]; k++)
                {
                    const unsigned char *a = (const unsigned char *)he->h_addr_list[k];
                    add_local( local, &nlocal, MAX_LOCAL, (unsigned long)a[0]
                                                        | ((unsigned long)a[1] << 8)
                                                        | ((unsigned long)a[2] << 16)
                                                        | ((unsigned long)a[3] << 24) );
                }
        }
    }

    /* join the group once per local interface address, like the SDK does;
     * graceful per-address failures (down bridges, odd VPN carriers),
     * fatal only if no join works at all */
    for (k = 0; k < nlocal; k++)
    {
        struct in_addr ia;
        ia.s_addr = local[k];
        mreq.imr_multiaddr.s_addr = inet_addr( LINK_GROUP );
        mreq.imr_interface.s_addr = local[k];
        if (setsockopt( s, IPPROTO_IP, IP_ADD_MEMBERSHIP, (const char *)&mreq, sizeof(mreq) ))
        {
            join_fail++;
            P( "warning: IP_ADD_MEMBERSHIP via %s failed: %d\r\n",
               inet_ntoa( ia ), WSAGetLastError() );
        }
        else
        {
            if (njoined < MAX_LOCAL) joined[njoined++] = local[k];
            P( "linkprobe: joined %s via %s\r\n", LINK_GROUP, inet_ntoa( ia ) );
        }
    }
    P( "linkprobe: interface joins: %d ok, %d failed\r\n", njoined, join_fail );
    if (!njoined)
    {
        P( "IP_ADD_MEMBERSHIP failed on all %d local addresses\r\n", nlocal );
        closesocket( s ); WSACleanup();
        return 1;
    }

    zero( &dest, sizeof(dest) );
    dest.sin_family = AF_INET;
    dest.sin_port = htons( LINK_PORT );
    dest.sin_addr.s_addr = inet_addr( LINK_GROUP );

    /* TX phase: five rounds 250 ms apart; in each round send the alive
     * datagram once per joined interface via IP_MULTICAST_IF, the SDK's
     * per-interface transmit, and required here because a stray
     * 224.0.0.0/4 route would otherwise pick the egress interface for us */
    for (i = 0; i < TX_COUNT; i++)
    {
        for (k = 0; k < njoined; k++)
        {
            struct in_addr ia;
            ia.s_addr = joined[k];
            if (setsockopt( s, IPPROTO_IP, IP_MULTICAST_IF, (const char *)&ia, sizeof(ia) ))
            {
                tx_err++;
                P( "IP_MULTICAST_IF %s failed: %d\r\n", inet_ntoa( ia ), WSAGetLastError() );
                continue;
            }
            if (sendto( s, (const char *)alive, sizeof(alive), 0,
                        (struct sockaddr *)&dest, sizeof(dest) ) == SOCKET_ERROR)
            {
                tx_err++;
                P( "sendto #%d via %s failed: %d\r\n", i, inet_ntoa( ia ), WSAGetLastError() );
            }
        }
        if (i + 1 < TX_COUNT) Sleep( TX_GAP_MS );
    }

    /* RX phase: ~6 s of discovery traffic */
    deadline = GetTickCount() + LISTEN_MS;
    for (;;)
    {
        long remain = (long)(deadline - GetTickCount());   /* wrap-safe */
        fd_set rfds;
        struct timeval tv;
        int r, n;

        if (remain <= 0) break;
        tv.tv_sec = remain / 1000;
        tv.tv_usec = (remain % 1000) * 1000;
        FD_ZERO( &rfds );
        FD_SET( s, &rfds );
        r = select( 0, &rfds, NULL, NULL, &tv );
        if (r == SOCKET_ERROR) { P( "select failed: %d\r\n", WSAGetLastError() ); break; }
        if (r == 0) break;

        fl = sizeof(from);
        zero( &from, sizeof(from) );
        n = recvfrom( s, (char *)pkt, sizeof(pkt), 0, (struct sockaddr *)&from, &fl );
        if (n <= 0) continue;
        rx_total++;
        if (n < 20 || !has_magic( pkt )) continue;
        rx_magic++;

        /* nodeId = bytes 12..20 of the datagram */
        if (eq8( pkt + 12, self_id ))
            rx_self = 1;
        else
        {
            for (k = 0; k < npeers; k++) if (eq8( peers[k], pkt + 12 )) break;
            if (k == npeers && npeers < MAX_PEERS)
            {
                for (i = 0; i < 8; i++) peers[npeers][i] = pkt[12 + i];
                npeers++;
            }
        }

        /* source IP local? (127.0.0.0/8 or one of our own interface addrs) */
        {
            unsigned long sa = from.sin_addr.s_addr;
            int is_local = ((sa & 0xff) == 0x7f);
            for (k = 0; k < nlocal; k++) if (local[k] == sa) is_local = 1;
            if (!is_local) rx_network = 1;
        }
    }

    closesocket( s );
    WSACleanup();

    P( "linkprobe: tx %d/%d alive on %d iface(s), rx total %d, valid _asdp_v1 %d\r\n",
       TX_COUNT * njoined - tx_err, TX_COUNT * njoined, njoined, rx_total, rx_magic );
    P( "LINKPROBE TX %s\r\n", tx_err ? "FAIL" : "OK" );
    P( "LINKPROBE RX-LOOPBACK %s\r\n", rx_self ? "OK" : "FAIL" );
    P( "LINKPROBE RX-NETWORK %s\r\n", rx_network ? "OK" : "FAIL" );
    P( "LINKPROBE PEERS: %d\r\n", npeers );

    return (!tx_err && rx_self) ? 0 : 1;
}
