#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 43;
use Test::Mojo;

BEGIN { require FindBin; $ENV{MOJO_HOME} = "$FindBin::Bin"; }

require "$FindBin::Bin/../bootylicious";

my $app = app();

my $t = Test::Mojo->new;

# Index page
$t->get_ok('/')->status_is(200)->content_like(qr/booty/);

$t->get_ok('/index.html')->status_is(200)->content_like(qr/booty/);

# Index rss page
$t->get_ok('/index.rss')->status_is(200)->content_like(qr/rss/);

# Archive page
$t->get_ok('/articles.html')->status_is(200)->content_like(qr/Archive/);
$t->get_ok('/articles/2010.html')->status_is(200)->content_like(qr/Archive/);
$t->get_ok('/articles/2010/10.html')->status_is(200)
  ->content_like(qr/Archive/);

# Tags page
$t->get_ok('/tags.html')->status_is(200)->content_like(qr/Tags/);
$t->get_ok('/tags/foo.html')->status_is(200)->content_like(qr/foo/);

# Article Pages
$t->get_ok('/articles/2010/10/foo.html')->status_is(200);

# 404
$t->get_ok('/foo.html')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Articles
$t->get_ok('/articles/foo/foo/foo.html')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Drafts
$t->get_ok('/drafts/foo.html')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Pages
$t->get_ok('/pages/foo.html')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Pages
$t->get_ok('/../../etc/passwd')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Pages
$t->get_ok("/articles/2010/10/e,cho.html")->status_is(404);
