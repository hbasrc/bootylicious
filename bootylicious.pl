#!/usr/bin/env perl

BEGIN { use FindBin; use lib "$FindBin::Bin/mojo/lib" }

use Mojolicious::Lite;
use Mojo::Date;
use Pod::Simple::HTML;
require Time::Local;
use Mojo::ByteStream 'b';

my %config = (
    name  => $ENV{BOOTYLICIOUS_USER}  || 'whoami',
    email => $ENV{BOOTYLICIOUS_EMAIL} || '',
    title => $ENV{BOOTYLICIOUS_TITLE} || 'Just another blog',
    about => $ENV{BOOTYLICIOUS_ABOUT} || 'Perl hacker',
    description => $ENV{BOOTYLICIOUS_DESCR} || 'I do not know if I need this',
    articles_dir => $ENV{BOOTYLICIOUS_ARTICLESDIR} || 'articles',
    public_dir   => $ENV{BOOTYLICIOUS_PUBLICDIR}   || 'public',
    footer       => $ENV{BOOTYLICIOUS_FOOTER}
      || '<h1>bootylicious</h1> is powered by <em>Mojolicious::Lite</em> & <em>Pod::Simple::HTML</em>'
);

$config{$_} = b($config{$_})->decode('utf8')->to_string
  foreach keys %config;

get '/' => sub {
    my $c = shift;

    my $article;
    my @articles = _parse_articles($c, limit => 10);

    if (@articles) {
        $article = $articles[0];
    }

    $c->stash(
        config   => \%config,
        article  => $article,
        articles => \@articles
    );
} => 'index';

get '/articles' => sub {
    my $c = shift;

    my $root = $c->app->home;

    my $last_modified = Mojo::Date->new;

    my @articles = _parse_articles($c, limit => 0);
    if (@articles) {
        $last_modified = $articles[0]->{mtime};

        #return 1 unless _is_modified($c, $last_modified);
    }

    $c->res->headers->header('Last-Modified' => $last_modified);

    $c->stash(
        articles      => \@articles,
        last_modified => $last_modified,
        config        => \%config
    );
} => 'articles';

get '/tags/:tag' => sub {
    my $c = shift;

    my $tag = $c->stash('tag');

    my @articles = grep {
        grep {/^$tag$/} @{$_->{tags}}
    } _parse_articles($c, limit => 0);

    my $last_modified = Mojo::Date->new;
    if (@articles) {
        $last_modified = $articles[0]->{mtime};
    }

    $c->stash(
        config        => \%config,
        articles      => \@articles,
        last_modified => $last_modified
    );

    if ($c->stash('format') && $c->stash('format') eq 'rss') {
        $c->stash(template => 'articles');
    }
} => 'tag';

get '/tags' => sub {
    my $c = shift;

    my $tags = {};

    foreach my $article (_parse_articles($c, limit => 0)) {
        foreach my $tag (@{$article->{tags}}) {
            $tags->{$tag}->{count} ||= 0;
            $tags->{$tag}->{count}++;
        }
    }

    $c->stash(config => \%config, tags => $tags);
} => 'tags';

get '/articles/:year/:month/:day/:alias' => sub {
    my $c = shift;

    my $root = $c->app->home->rel_dir($config{articles_dir});
    my $path = join('/',
        $root,
        $c->stash('year')
          . $c->stash('month')
          . $c->stash('day') . '-'
          . $c->stash('alias')
          . '.pod');

    return $c->app->static->serve_404($c) unless -r $path;

    my $last_modified = Mojo::Date->new((stat($path))[9]);

    my $data;
    $data = _parse_article($c, $path)
      or return $c->app->static->serve_404($c);

    #return 1 unless _is_modified($c, $last_modified);

    $c->stash(article => $data, template => 'article', config => \%config);

#$c->res->headers->header('Last-Modified' => Mojo::Date->new($last_modified));
} => 'article';

sub makeup {
    my $public_dir = app->home->rel_dir($config{public_dir});

    # CSS, JS auto import
    foreach my $type (qw/css js/) {
        $config{$type} =
          [map { s/^$public_dir\///; $_ } glob("$public_dir/*.$type")];
    }
}

sub _is_modified {
    my $c = shift;
    my ($last_modified) = @_;

    my $date = $c->req->headers->header('If-Modified-Since');
    return 1 unless $date;

    return 1 unless Mojo::Date->new($date)->epoch == $last_modified->epoch;

    $c->res->code(304);

    return 0;
}

sub _parse_articles {
    my $c      = shift;
    my %params = @_;

    my @files =
      sort { $b cmp $a }
      glob(app->home->rel_dir($config{articles_dir}) . '/*.pod');

    @files = splice(@files, 0, $params{limit}) if $params{limit};

    my @articles;
    foreach my $file (@files) {
        my $data = _parse_article($c, $file);
        next unless $data && %$data;

        push @articles, $data;
    }

    return @articles;
}

my %_articles;

sub _parse_article {
    my $c    = shift;
    my $path = shift;

    return unless $path;

    return $_articles{$path} if $_articles{$path};

    unless ($path =~ m/\/(\d\d\d\d)(\d\d)(\d\d)-(.*?)\.pod$/) {
        $c->app->log->debug("Ignoring $path: unknown file");
        return;
    }
    my ($year, $month, $day, $name) = ($1, $2, $3, $4);

    my $epoch = 0;
    eval {
        $epoch = Time::Local::timegm(0, 0, 0, $day, $month - 1, $year - 1900);
    };
    if ($@ || $epoch < 0) {
        $c->app->log->debug("Ignoring $path: wrong timestamp");
        return;
    }

    my $parser = Pod::Simple::HTML->new;

    $parser->force_title('');
    $parser->html_header_before_title('');
    $parser->html_header_after_title('');
    $parser->html_footer('');

    my $title   = '';
    my $content = '';

    open FILE, "<:encoding(UTF-8)", $path;
    my $string = join("\n", <FILE>);
    close FILE;

    $parser->output_string(\$content);
    eval { $parser->parse_string_document($string) };
    if ($@) {
        $c->app->log->debug("Ignoring $path: parser error");
        return;
    }

    # Hacking
    $content =~ s{<a name='___top' class='dummyTopAnchor'\s*></a>\n}{}g;
    $content =~ s{<a class='u'.*?name=".*?"\s*>(.*?)</a>}{$1}sg;
    $content =~ s{^\s*<h1>NAME</h1>\s*<p>(.*?)</p>}{}sg;
    $title = $1 || $name;

    my $tags = [];
    if ($content =~ s{^\s*<h1>TAGS</h1>\s*<p>(.*?)</p>}{}sg) {
        my $list = $1; $list =~ s/(?:\r|\n)*//gs;
        @$tags = map { s/^\s+//; s/\s+$//; $_ } split(/,/, $list);
    }

    return $_articles{$path} = {
        title   => $title,
        tags    => $tags,
        content => $content,
        mtime   => _format_date(Mojo::Date->new((stat($path))[9])),
        created => _format_date(Mojo::Date->new($epoch)),
        year    => $year,
        month   => $month,
        day     => $day,
        name    => $name
    };
}

sub _format_date {
    my $date = shift;

    $date = $date->to_string;

    $date =~ s/ [^ ]*? GMT$//;

    return $date;
}

app->types->type(rss => 'application/rss+xml');

makeup;

shagadelic(@ARGV ? @ARGV : 'cgi');

__DATA__

@@ index.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% if (my $article = $self->stash('article')) {
    <div class="text">
        <h1 class="title"><%= $article->{title} %></h1>
        <div class="created"><%= $article->{created} %></div>
        <div class="tags">
% foreach my $tag (@{$article->{tags}}) {
        <a href="<%= $self->url_for('tag', tag => $tag) %>"><%= $tag %></a>
% }
        </div>
        <%= $article->{content} %>
    </div>
    <div id="subfooter">
    <h2>Last articles</h2>
    <ul>
% foreach my $article (@{$self->stash('articles')}) {
        <li>
            <a href="<%== $self->url_for('article', year => $article->{year}, month => $article->{month}, day => $article->{day}, alias => $article->{name}) %>.html"><%= $article->{title} %></a><br />
            <div class="created"><%= $article->{created} %></div>
        </li>
% }
    </ul>
    </div>
% }
% else {
Not much here yet :(
% }

@@ articles.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $articles = $self->stash('articles');
% my $tmp;
% my $new = 0;
<div class="text">
<h1>Archive</h1>
<br />
% foreach my $article (@$articles) {
%     if (!$tmp || $article->{year} ne $tmp->{year}) {
    <%= "</ul>" if $tmp %>
    <b><%= $article->{year} %></b>
<ul>
%     }

    <li>
        <a href="<%== $self->url_for('article', year => $article->{year}, month => $article->{month}, day => $article->{day}, alias => $article->{name}) %>"><%= $article->{title} %></a><br />
        <div class="created"><%= $article->{created} %></div>
    </li>

%     $tmp = $article;
% }
</div>

@@ articles.rss.epl
% my $self = shift;
% my $articles = $self->stash('articles');
% my $last_modified = $self->stash('last_modified');
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xml:base="<%= $self->req->url->base %>"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title><%= $self->stash('config')->{title} %></title>
        <link><%= $self->req->url->base %></link>
        <description><%= $self->stash('config')->{description} %></description>
        <pubDate><%= $last_modified %></pubDate>
        <lastBuildDate><%= $last_modified %></lastBuildDate>
        <generator>Mojolicious::Lite</generator>
    </channel>
% foreach my $article (@$articles) {
% my $link = $self->url_for('article', article => $article->{name}, format => 'html')->to_abs;
    <item>
      <title><%== $article->{title} %></title>
      <link><%= $link %></link>
      <description><%== $article->{content} %></description>
% foreach my $tag (@{$article->{tags}}) {
      <category><%= $tag %></category>
% }
      <pubDate><%= $article->{mtime} %></pubDate>
      <guid><%= $link %></guid>
    </item>
% }
</rss>

@@ tags.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $tags = $self->stash('tags');
<div class="text">
<h1>Tags</h1>
<br />
<div class="tags">
% foreach my $tag (keys %$tags) {
<a href="<%= $self->url_for('tag', tag => $tag) %>"><%= $tag %></a><sub>(<%= $tags->{$tag}->{count} %>)</sub>
% }
</div>
</div>

@@ tag.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $tag = $self->stash('tag');
% my $articles = $self->stash('articles');
<div class="text">
<h1>Tag <%= $tag %></h1>
<br />
% foreach my $article (@$articles) {
        <a href="<%== $self->url_for('article', year => $article->{year}, month => $article->{month}, day => $article->{day}, alias => $article->{name}) %>"><%= $article->{title} %></a><br />
        <div class="created"><%= $article->{created} %></div>
    </li>
% }
</div>

@@ article.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $article = $self->stash('article');
<div class="text">
<h1 class="title"><%= $article->{title} %></h1>
<div class="created"><%= $article->{created} %>
% if ($article->{created} ne $article->{mtime}) {
, modified <span class="modified"><%= $article->{mtime} %></span>
% }
</div>
<div class="tags">
% foreach my $tag (@{$article->{tags}}) {
<a href="<%= $self->url_for('tag', tag => $tag) %>"><%= $tag %></a>
% }
</div>
<%= $article->{content} %>
</div>

@@ layouts/wrapper.html.epl
% my $self = shift;
% my $config = $self->stash('config');
% $self->res->headers->content_type('text/html; charset=utf-8');
<!html>
    <head>
        <title><%= $config->{title} %></title>
% foreach my $file (@{$config->{css}}) {
        <link rel="stylesheet" href="/<%= $file %>" type="text/css" />
% }
% if (!@{$config->{css}}) {
        <style type="text/css">
            body {background: #fff;font-family: "Helvetica Neue", Arial, Helvetica, sans-serif;}
            h1,h2,h3,h4,h5 {font-family: times, Times New Roman, times-roman, georgia, serif; line-height: 40px; letter-spacing: -1px; color: #444; margin: 0 0 0 0; padding: 0 0 0 0; font-weight: 100;}
            a,a:active {color:#555}
            a:hover{color:#000}
            a:visited{color:#000}
            #body {width:65%;margin:auto}
            #header {text-align:center;padding:2em;border-bottom: 1px solid #000}
            h1#title{font-size:3em}
            h2#descr{font-size:1.5em;color:#999}
            span#name {font-weight:bold}
            span#about {font-style:italic}
            #menu {text-align:right}
            #content {background:#FFFFFF}
            .created, .modified {color:#999;margin-left:10px;font-size:small;font-style:italic;padding-bottom:0.5em}
            .modified {margin:0px}
            .tags{margin-left:10px;text-transform:uppercase;}
            .text {padding:2em;}
            .text h1.title {font-size:2.5em}
            #subfooter {padding:2em;border-top:#000000 1px solid}
            #footer {text-align:center;padding:2em;border-top:#000000 1px solid}
        </style>
% }
        <link rel="alternate" type="application/rss+xml" title="<%= $config->{title} %>" href="<%= $self->url_for('articles', format => 'rss') %>" />
    </head>
    <body>
        <div id="body">
            <div id="header">
                <h1 id="title"><a href="<%= $self->url_for('index') %>"><%= $config->{title} %></a></h1>
                <h2 id="descr"><%= $config->{description} %></h2>
                <span id="name"><%= $config->{name} %></span>, <span id="about"><%= $config->{about} %></span>
                <div id="menu">
                    <a href="<%= $self->url_for('index', format => '') %>">index</a>
                    <a href="<%= $self->url_for('tags') %>">tags</a>
                    <a href="<%= $self->url_for('articles') %>">archive</a>
                </div>
            </div>

            <div id="content">
            <%= $self->render_inner %>
            </div>

            <div id="footer"><small><%= $config->{footer} %></small></div>
        </div>
% foreach my $file (@{$config->{js}}) {
        <script type="text/javascript" href="/<%= $file %>" />
% }
    </body>
</html>

__END__

=head1 NAME

Bootylicious -- one-file blog on Mojo steroids!

=head1 SYNOPSIS

    $ perl bootylicious.pl daemon

=head1 DESCRIPTION

Bootylicious is a minimalistic blogging application built on
L<Mojolicious::Lite>. You start with just one file, but it is easily extendable
when you add new templates, css files etc.

=head1 CONFIGURATION

=head1 FILESYSTEM

All the articles must be stored in BOOTYLICIOUS_ARTICLESDIR directory with a
name like 20090730-my-new-article.pod. They are parsed with
L<Pod::Simple::HTML>.

=head1 TEMPLATES

Embedded templates will work just fine, but when you want to have something more
advanced just create a template in templates/ directory with the same name but
with a different extension.

For example there is index.html.epl, thus templates/index.html.epl should be
created with a new content.

=head1 DEVELOPMENT

=head2 Repository

    http://github.com/vti/bootylicious/commits/master

=head1 SEE ALSO

L<Mojo> L<Mojolicious> L<Mojolicious::Lite>

=head1 AUTHOR

Viacheslav Tykhanovskyi, C<vti@cpan.org>.

=head1 COPYRIGHT

Copyright (C) 2008-2009, Viacheslav Tykhanovskyi.

This program is free software, you can redistribute it and/or modify it under
the same terms as Perl 5.10.

=cut