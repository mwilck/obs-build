################################################################
#
# Copyright (c) 2021 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################

package PBuild::RemoteRegistry;

use strict;

use LWP::UserAgent;
use URI;
use Data::Dumper;

use PBuild::Verify;
use Build::SimpleJSON;

eval { require JSON::XS };
*JSON::XS::decode_json = sub {die("JSON::XS is not available\n")} unless defined &JSON::XS::decode_json;

# 
# simple anon bearer authenticator
# 
sub bearer_authenticate {
  my($class, $ua, $proxy, $auth_param, $response, $request, $arg, $size) = @_;
  my $realm = $auth_param->{'realm'};
  die("bearer auth did not provide a realm\n") unless $realm;
  die("bearer realm is not http/https\n") unless $realm =~ /^https?:\/\//i;
  my $auri = URI->new($realm);
  my @afields;
  for ('service', 'scope') {
    push @afields, $_, $auth_param->{$_} if defined $auth_param->{$_};
  }
  print "requesting bearer auth from $realm [@afields]\n";
  $auri->query_form($auri->query_form, @afields);
  my $ares = $ua->get($auri);
  return $request unless $ares->is_success;
  my $reply = JSON::XS::decode_json($ares->decoded_content);
  my $token = $reply->{'token'} || $reply->{'access_token'};
  return $request unless $token;
  my $url = $proxy ? $request->{proxy} : $request->uri_canonical;
  my $host_port = $url->host_port;
  my $h = $ua->get_my_handler('request_prepare', 'm_host_port' => $host_port, sub {
    $_[0]{callback} = sub { $_[0]->header('Authorization' => "Bearer $token") };
  });
  return $ua->request($request->clone, $arg, $size, $response);
}

*LWP::Authen::Bearer::authenticate = \&bearer_authenticate;

#
# convert arch to goarch/govariant
#
sub arch2goarch {
  my ($arch) = @_;
  return ('amd64') if $arch eq 'x86_64';
  return ('386') if $arch =~ /^i[3456]86$/;
  return ('arm64', 'v8') if $arch eq 'aarch64';
  return ('arm', "v$1") if $arch =~ /^armv(\d+)/;
  return $arch;
}

#
# select a matching manifest from a manifest index (aka fat manifest)
#
sub select_manifest {
  my ($arch, $manifests) = @_;
  my ($goarch, $govariant) = arch2goarch($arch);
  for my $m (@{$manifests || []}) {
    next unless $m->{'digest'};
    if ($m->{'platform'}) {
      next if $m->{'platform'}->{'architecture'} ne $goarch;
      next if $m->{'platform'}->{'variant'} && $govariant && $m->{'platform'}->{'variant'} ne $govariant;
    }
    return $m;
  }
  return undef;
}

#
# query a registry about a container
#
sub queryremotecontainer {
  my ($ua, $arch, $registry, $repotag) = @_;
  $repotag .= ":latest" unless $repotag =~ /:[^\/:]+$/;
  die unless $repotag =~ /^(.*):([^\/:]+)$/;
  my ($repository, $tag) = ($1, $2);
  $repository = "library/$repository" if $repository !~ /\// && $registry =~ /docker.io\/?$/;

  my $response = $ua->get("$registry/v2/$repository/manifests/$tag", 'Accept', 'application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json');
  if (!$response->is_success) {
    my $code = $response->code;
    return undef if $code eq '404';
    die("rpc failed: $code!\n");
  }
  my $ct = $response->header('content_type');
  die("no content type set in answer\n") unless $ct;
  my $r = JSON::XS::decode_json($response->decoded_content);
  if ($ct eq 'application/vnd.docker.distribution.manifest.list.v2+json' || $ct eq 'application/vnd.oci.image.index.v1+json') {
    # fat manifest, select the one we want
    my $manifest = select_manifest($arch, $r->{'manifests'} || []);
    return undef unless $manifest;
    $response = $ua->get("$registry/v2/$repository/manifests/$manifest->{'digest'}", 'Accept', 'application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json');
    die("failed!\n") unless $response->is_success;
    $ct = $response->header('content_type');
    die("no content type set in answer\n") unless $ct;
    $r = JSON::XS::decode_json($response->decoded_content);
  }

  my @blobs;
  die("manifest has no config\n") unless $r->{'config'};
  push @blobs, $r->{'config'};
  push @blobs, @{$r->{'layers'} || []};
  PBuild::Verify::verify_digest($_->{'digest'}) for @blobs;
  my $id = $blobs[0]->{'digest'};
  $id =~ s/.*://;
  $id = substr($id, 0, 32);
  my $name = "container:$repotag";
  my $version = 0;
  my $q = {
    'name' => $name,
    'version' => $version,
    'arch' => 'noarch',
    'source' => $name,
    'provides' => [ "$name = $version" ],
    'hdrmd5' => $id,
    'location' => $repository,
    'blobs' => \@blobs,
  };
  return $q;
}

#
# create a user agent for download
#
sub create_ua {
  return LWP::UserAgent->new(agent => "openSUSE build script", timeout => 42, ssl_opts => { verify_hostname => 1 });
}

#
# get data from a registry for a set of containers
#
sub fetchrepo {
  my ($bconf, $arch, $repodir, $url, $repotags) = @_;
  my @bins;
  my $ua = create_ua();
  for my $repotag (@{$repotags || []}) {
    my $bin = queryremotecontainer($ua, $arch, $url, $repotag);
    push @bins, $bin if $bin;
  }
  return \@bins;
}

#
# download the blobs needed to reconstruct a container
#
sub fetchbinaries {
  my ($repo, $bins) = @_;
  my $repodir = $repo->{'dir'};
  my $url = $repo->{'url'};
  my $nbins = @$bins;
  die("bad repo\n") unless $url;
  my %tofetch;
  for my $bin (@$bins) {
    my $blobs = $bin->{'blobs'};
    die unless $blobs;
    for my $blob (@$blobs) {
      my $digest = $blob->{'digest'};
      die unless $digest;
      next if -s "$repodir/blob.$digest";
      $tofetch{"$bin->{'location'}/$digest"} = 1;
    }
  }
  return unless %tofetch;
  my @tofetch = sort keys %tofetch;
  my $ntofetch = @tofetch;
  print "fetching $ntofetch container blobs from $url\n";
  my $ua = create_ua();
  PBuild::Util::mkdir_p($repodir);
  for my $tofetch (@tofetch) {
    next unless $tofetch =~ /^(.*)\/(.*)?$/;
    my ($repository, $digest) = ($1, $2);
    next if -s "$repodir/blob.$digest";
    my $res = $ua->mirror("$url/v2/$repository/blobs/$digest", "$repodir/.blob.$digest.$$");
    die("unknown blob $repository/$digest\n") unless$res->is_success;
    rename("$repodir/.blob.$digest.$$", "$repodir/blob.$digest") || die;
  }
}

#
# create the head/pad data for a tar file entry
#
sub maketarhead {
  my ($name, $size, $mtime) = @_;

  my $h = "\0\0\0\0\0\0\0\0" x 64;
  my $pad = '';
  return ("$h$h") unless defined $name;
  my $tartype = '0';
  die("name too big\n") if length($name) > 100;
  my $mode = sprintf("%07o", 0x81a4);
  my $fsize = sprintf("%011o", $size);
  my $fmtime = sprintf("%011o", $mtime);
  substr($h, 0, length($name), $name);
  substr($h, 100, length($mode), $mode);
  substr($h, 108, 15, "0000000\0000000000");    # uid/gid
  substr($h, 124, length($fsize), $fsize);
  substr($h, 136, length($fmtime), $fmtime);
  substr($h, 148, 8, '        ');
  substr($h, 156, 1, $tartype);
  substr($h, 257, 8, "ustar\00000");            # magic/version
  substr($h, 329, 15, "0000000\0000000000");    # major/minor
  substr($h, 148, 7, sprintf("%06o\0", unpack("%16C*", $h)));
  $pad = "\0" x (512 - $size % 512) if $size % 512;
  return ($h, $pad);
}

#
# reconstruct a container from blobs
#
sub construct_containertar {
  my ($repodir, $q, $dst) = @_;
  my $fd;
  open ($fd, '>', $dst) || die("$dst: $!\n");
  my $mtime = time();
  my $blobs = $q->{'blobs'};
  die unless $blobs;
  for my $blob (@$blobs) {
    my $digest = $blob->{'digest'};
    die unless $digest;
    my $bfd;
    open ($bfd, '<', "$repodir/blob.$digest") || die("$repodir/blob.$digest: $!\n");
    my @s = stat($bfd);
    die unless @s;
    my $size = $s[7];
    my ($head, $pad) = maketarhead($digest, $size, $mtime);
    print $fd $head;
    while ($size > 0) {
      my $chunk = $size > 16384 ? 16384 : $size;
      my $b = '';
      die("unexpected read error in blob\n") unless sysread($bfd, $b, $chunk);
      print $fd $b;
      $size -= length($b);
    }
    print $fd $pad;
    close($bfd);
  }
  my $tag = $q->{'name'};
  $tag =~ s/^container://;
  my @repotags = ( $tag );
  my @digests = map {$_->{'digest'}} @$blobs;
  my $configdigest = shift @digests;
  my $manifest = {
    'Config' => $configdigest,
    'Layers' => \@digests,
    'RepoTags' => \@repotags,
    '_order' => [ 'Config', 'RepoTags', 'Layers' ],
  };
  my $manifest_json = Build::SimpleJSON::unparse([ $manifest ], 'ugly' => 1);
  my ($head, $pad) = maketarhead('manifest.json', length($manifest_json), $mtime);
  print $fd "$head$manifest_json$pad".maketarhead();
  close($fd) || die;
}

1;
