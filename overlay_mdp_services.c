/*
Copyright (C) 2010-2012 Paul Gardner-Stephen, Serval Project.
 
This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.
 
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
 
You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

#include <sys/stat.h>
#include "serval.h"
#include "str.h"
#include "strbuf.h"
#include "overlay_buffer.h"
#include "overlay_address.h"
#include "overlay_packet.h"
#include "mdp_client.h"
#include "crypto.h"


int overlay_mdp_service_dnalookup(overlay_mdp_frame *mdp)
{
  IN();
  int cn=0,in=0,kp=0;
  char did[64+1];
  int pll=mdp->out.payload_length;
  if (pll>64) pll=64;
  /* get did from the packet */
  if (mdp->out.payload_length<1) {
    RETURN(WHY("Empty DID in DNA resolution request")); }
  bcopy(&mdp->out.payload[0],&did[0],pll);
  did[pll]=0;
  
  if (debug & DEBUG_MDPREQUESTS)
    DEBUG("MDP_PORT_DNALOOKUP");
  
  int results=0;
  while(keyring_find_did(keyring,&cn,&in,&kp,did))
    {
      /* package DID and Name into reply (we include the DID because
	 it could be a wild-card DID search, but the SID is implied 
	 in the source address of our reply). */
      if (keyring->contexts[cn]->identities[in]->keypairs[kp]->private_key_len > DID_MAXSIZE) 
	/* skip excessively long DID records */
	continue;
      const unsigned char *packedSid = keyring->contexts[cn]->identities[in]->keypairs[0]->public_key;
      const char *unpackedDid = (const char *) keyring->contexts[cn]->identities[in]->keypairs[kp]->private_key;
      const char *name = (const char *)keyring->contexts[cn]->identities[in]->keypairs[kp]->public_key;
      // URI is sid://SIDHEX/DID
      strbuf b = strbuf_alloca(SID_STRLEN + DID_MAXSIZE + 10);
      strbuf_puts(b, "sid://");
      strbuf_tohex(b, packedSid, SID_SIZE);
      strbuf_puts(b, "/local/");
      strbuf_puts(b, unpackedDid);
      overlay_mdp_dnalookup_reply(&mdp->out.src, packedSid, strbuf_str(b), unpackedDid, name);
      kp++;
      results++;
    }
  if (!results) {
    /* No local results, so see if servald has been configured to use
       a DNA-helper that can provide additional mappings.  This provides
       a generalised interface for resolving telephone numbers into URIs.
       The first use will be for resolving DIDs to SIP addresses for
       OpenBTS boxes run by the OTI/Commotion project. 
       
       The helper is run asynchronously, and the replies will be delivered
       when results become available, so this function will return
       immediately, so as not to cause blockages and delays in servald.
    */
    dna_helper_enqueue(mdp, did, mdp->out.src.sid);
    monitor_tell_formatted(MONITOR_DNAHELPER, "LOOKUP:%s:%d:%s\n", 
			   alloca_tohex_sid(mdp->out.src.sid), mdp->out.src.port, 
			   did);
  }
  RETURN(0);
}

int overlay_mdp_service_echo(overlay_mdp_frame *mdp)
{
  /* Echo is easy: we swap the sender and receiver addresses (and thus port
     numbers) and send the frame back. */
  IN();

  /* Swap addresses */
  overlay_mdp_swap_src_dst(mdp);
  mdp->out.ttl=0;
  
  /* Prevent echo:echo connections and the resulting denial of service from triggering endless pongs. */
  if (mdp->out.dst.port==MDP_PORT_ECHO) {
    RETURN(WHY("echo loop averted"));
  }
  /* If the packet was sent to broadcast, then replace broadcast address
     with our local address. For now just responds with first local address */
  if (is_sid_broadcast(mdp->out.src.sid))
    {
      if (my_subscriber)		  
	bcopy(my_subscriber->sid,
	      mdp->out.src.sid,SID_SIZE);
      else
	/* No local addresses, so put all zeroes */
	bzero(mdp->out.src.sid,SID_SIZE);
    }
  
  /* Always send PONGs auth-crypted so that the receipient knows
     that they are genuine, and so that we avoid the extra cost 
     of signing (which is slower than auth-crypting) */
  int preserved=mdp->packetTypeAndFlags;
  mdp->packetTypeAndFlags&=~(MDP_NOCRYPT|MDP_NOSIGN);
  
  /* queue frame for delivery */
  overlay_mdp_dispatch(mdp,0 /* system generated */,
		       NULL,0);
  mdp->packetTypeAndFlags=preserved;
  
  /* and switch addresses back around in case the caller was planning on
     using MDP structure again (this happens if there is a loop-back reply
     and the frame needs sending on, as happens with broadcasts.  MDP ping
     is a simple application where this occurs). */
  overlay_mdp_swap_src_dst(mdp);
  RETURN(0);
}

int overlay_mdp_try_interal_services(overlay_mdp_frame *mdp)
{
  IN();
  switch(mdp->out.dst.port) {
  case MDP_PORT_VOMP:
    RETURN(vomp_mdp_received(mdp));
  case MDP_PORT_KEYMAPREQUEST:
    /* Either respond with the appropriate SAS, or record this one if it
       verifies out okay. */
    if (debug & DEBUG_MDPREQUESTS) DEBUG("MDP_PORT_KEYMAPREQUEST");
    RETURN(keyring_mapping_request(keyring,mdp));
  case MDP_PORT_DNALOOKUP: /* attempt to resolve DID to SID */
    RETURN(overlay_mdp_service_dnalookup(mdp));
    break;
  case MDP_PORT_ECHO: /* well known ECHO port for TCP/UDP and now MDP */
    RETURN(overlay_mdp_service_echo(mdp));
    break;
  default:
    /* Unbound socket.  We won't be sending ICMP style connection refused
       messages, partly because they are a waste of bandwidth. */
    RETURN(WHYF("Received packet for which no listening process exists (MDP ports: src=%d, dst=%d",
		mdp->out.src.port,mdp->out.dst.port));
  }
}
