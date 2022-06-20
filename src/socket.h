// SPDX-FileCopyrightText: 2000-2002 Michael R. Elkins <me@mutt.org>
// SPDX-FileCopyrightText: 2002-2022 Oswald Buddenhagen <ossi@users.sf.net>
// SPDX-License-Identifier: GPL-2.0-or-later WITH LicenseRef-isync-GPL-exception
/*
 * mbsync - mailbox synchronizer
 */

#ifndef SOCKET_H
#define SOCKET_H

#include "common.h"

#ifdef HAVE_LIBZ
#include <zlib.h>
#endif

#ifdef HAVE_LIBSSL
# include <openssl/ssl.h>
# include <openssl/x509.h>

enum {
	TLSv1 = 4,
	TLSv1_1 = 8,
	TLSv1_2 = 16,
	TLSv1_3 = 32
};
#endif

typedef struct {
	char *tunnel;
	char *host;
	ushort port;
	int timeout;
#ifdef HAVE_LIBSSL
	char *cert_file;
	char *client_certfile;
	char *client_keyfile;
	char *cipher_string;
	char system_certs;
	char ssl_versions;

	/* these are actually variables and are leaked at the end */
	char ssl_ctx_valid;
	STACK_OF(X509) *trusted_certs;
	SSL_CTX *SSLContext;
#endif
} server_conf_t;

typedef struct buff_chunk {
	struct buff_chunk *next;
	uint len;
	char data[1];
} buff_chunk_t;

typedef struct {
	/* connection */
	int fd;
	int state;
	const server_conf_t *conf; /* needed during connect */
#ifdef HAVE_IPV6
	struct addrinfo *addrs, *curr_addr; /* needed during connect */
#else
	struct addr_info *addrs, *curr_addr; /* needed during connect */
#endif
	char *name;
#ifdef HAVE_LIBSSL
	SSL *ssl;
	wakeup_t ssl_fake;
#endif
#ifdef HAVE_LIBZ
	z_streamp in_z, out_z;
	wakeup_t z_fake;
	int z_written;
#endif

	void (*bad_callback)( void *aux ); /* async fail while sending or listening */
	void (*read_callback)( void *aux ); /* data available for reading */
	void (*write_callback)( void *aux ); /* all *queued* data was sent */
	union {
		void (*connect)( int ok, void *aux );
		void (*starttls)( int ok, void *aux );
	} callbacks;
	void *callback_aux;

	notifier_t notify;
	wakeup_t fd_fake;
	wakeup_t fd_timeout;

	/* writing */
	buff_chunk_t *append_buf; /* accumulating buffer */
	buff_chunk_t *write_buf, **write_buf_append; /* buffer head & tail */
#ifdef HAVE_LIBZ
	uint append_avail; /* space left in accumulating buffer */
#endif
	uint write_offset; /* offset into buffer head */
	uint buffer_mem; /* memory currently occupied by buffers in the queue */

	/* reading */
	uint offset; /* start of filled bytes in buffer */
	uint bytes; /* number of filled bytes in buffer */
	uint scanoff; /* offset to continue scanning for newline at, relative to 'offset' */
	uint wanted;  // try to accumulate that many bytes before calling back; 0 => full line
	uint readsz;  // average size of bulk reads from the underlying socket, times 1.5
	char buf[100000];
#ifdef HAVE_LIBZ
	char z_buf[100000];
#endif
} conn_t;

// Shorter reads are assumed to be limited by round-trips.
#define MIN_BULK_READ 1000

/* call this before doing anything with the socket */
static INLINE void socket_init( conn_t *conn,
                                const server_conf_t *conf,
                                void (*bad_callback)( void *aux ),
                                void (*read_callback)( void *aux ),
                                void (*write_callback)( void *aux ),
                                void *aux )
{
	conn->conf = conf;
	conn->bad_callback = bad_callback;
	conn->read_callback = read_callback;
	conn->write_callback = write_callback;
	conn->callback_aux = aux;
	conn->fd = -1;
	conn->name = NULL;
	conn->write_buf_append = &conn->write_buf;
	conn->wanted = 1;
	conn->readsz = MIN_BULK_READ * 3 / 2;
}
void socket_connect( conn_t *conn, void (*cb)( int ok, void *aux ) );
void socket_start_tls(conn_t *conn, void (*cb)( int ok, void *aux ) );
void socket_start_deflate( conn_t *conn );
void socket_close( conn_t *sock );
void socket_expect_activity( conn_t *sock, int expect );
void socket_expect_bytes( conn_t *sock, uint len );
// Don't free return values. These functions never wait.
char *socket_read( conn_t *conn, uint min_len, uint max_len, uint *out_len );
char *socket_read_line( conn_t *conn );
typedef enum { KeepOwn = 0, GiveOwn } ownership_t;
typedef struct {
	char *buf;
	uint len;
	ownership_t takeOwn;
} conn_iovec_t;
void socket_write( conn_t *sock, conn_iovec_t *iov, int iovcnt );

#endif
