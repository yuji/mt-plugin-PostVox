# $id$
package MT::Plugin::PostVox;

use strict;
use warnings;

use MT;
use XML::Atom;

use constant NS_DC => 'http://purl.org/dc/elements/1.1/';

use base 'MT::Plugin';
our $VERSION = '0.07';

my $plugin = __PACKAGE__->new({
    name            => 'Post to Vox',
    description     => 'Automatic cross-posting to Vox. (This version supports only MT4.)',
    author_name     => 'Six Apart, Ltd.',
    author_link     => 'http://www.sixapart.com/',
    version         => $VERSION,
    settings        => new MT::PluginSettings([
        ['vox_username'],
        ['vox_password'],
        ['vox_url'],
        ['always_post'],
        ['excerpt_only'],
    ]),
    blog_config_template => 'config.tmpl',
});

MT->add_plugin($plugin);
MT->add_callback('MT::App::CMS::template_param.edit_entry', 9, $plugin, \&add_input_field);
MT->add_callback('CMSPostSave.entry', 9, $plugin, \&hdlr_post_save);
MT->add_callback('APIPostSave.entry', 9, $plugin, \&hdlr_api_post_save);

sub add_input_field {
    my ($eh, $app, $param, $tmpl) = @_;
    return unless UNIVERSAL::isa($tmpl, 'MT::Template');
 
    my $q = $app->param;
    my $blog_id = $q->param('blog_id');
    my $config = $plugin->get_config_hash('blog:'.$blog_id.':user:'.$app->user->id); 
    return unless ( $config->{vox_username} || $config->{vox_password} );

    my $entry_class = MT->model('entry');
    my $entry_id = $app->param('id');
    my $entry;
    if ($entry_id) {
        $entry = $entry_class->load($entry_id, { cached_ok => 1 });
    }
    my $innerHTML;
    my $already_posted = $entry && (($entry->tangent_cache || '') =~ m!http://www.vox.com!);
    if ($already_posted) {
        if ($entry->tangent_cache =~ m!(http://www.vox.com\S+)!i) {
            my @parts = split '/', $1;
            my $asset_id = pop @parts;
            $innerHTML = "Update <a href='http://www.vox.com/compose/#id:$asset_id' target='_blank'> Vox post</a>";
        }
    } else {
        my $checked = '';
        $checked = "checked=\"checked\""
            if $config->{always_post};
        $innerHTML = "<input type='checkbox' id='allow_postvox' name='allow_postvox' $checked value='1' /> Cross post to Vox";
    }

    my $host_node = $tmpl->getElementById('status')
        or return $app->error('cannot get the status block');
    my $block_node = $tmpl->createElement('app:setting', {
        id => 'allow_postvox',
        label => 'Cross Posting',  })
        or return $app->error('cannot create the element');
    $block_node->innerHTML( $innerHTML );
    $tmpl->insertBefore($block_node, $host_node)
        or return $app->error('failed to insertBefore.');
}

sub hdlr_api_post_save {
    return $plugin->_cross_post(@_);
}

sub hdlr_post_save {
    my ($cb, $app, $obj, $orig) = @_;
    return $obj unless $app->param('allow_postvox');
    return $plugin->_cross_post($cb, $app, $obj, $orig);
}

sub _cross_post {
    my $self = shift;
    my ($cb, $app, $obj, $orig) = @_;
    my $blog_id = $obj->blog_id;
    my $user_id = $obj->author_id;
    my $config = $plugin->get_config_hash('blog:'.$blog_id.':user:'.$user_id);
    my $blog = MT::Blog->load($blog_id);

    return $obj unless ( $config->{vox_username} && $config->{vox_password} && $config->{vox_url} );

    my $entry_class = MT->model('entry');
    return $obj if $obj->status != MT::Entry::RELEASE();

    # APILINK
    my $apilink = $config->{vox_apilink};
    my $new_post = 1;
    if ( $obj->tangent_cache && $obj->tangent_cache =~ m!(http://www.vox.com\S+)!i) {
        $apilink = $1;
        $new_post = 0;
    } elsif (!$apilink) {
        my $url = $config->{vox_url};
        if ($url !~ m!^http://!i ) {
            $url = 'http://'.$url;
        }

        $apilink = $plugin->_find_apilink( $url );
        return $obj unless $apilink;
        
        $config->{vox_apilink} = $apilink;
        $plugin->set_config_value('vox_apilink', $apilink, 'blog:'.$blog_id.':user:'.$app->user->id);
    }

    # ENTRY
    require XML::Atom::Entry;
    my $enc = MT->instance->config('PublishCharset') || undef;
    my $entry = XML::Atom::Entry->new;
    $entry->title( MT::I18N::encode_text( $obj->title , $enc, 'utf-8' ) );

    my $text = '';
    my $excerpt_only = $config->{excerpt_only} || 0;

    if ($excerpt_only) {
        # Uses entry excerpt only
        my $words = $blog->words_in_excerpt;
        $words = 40 unless defined $words && $words ne '';
        $text = $obj->get_excerpt($words);
        $text .= "<br/><br/><a href='" . $obj->permalink . "' target='_blank'>read more...</a>";
    } else {
        # Apply filters to entry text and extended entry if available
        $text = $obj->text;
        my $text_more = $obj->text_more;
        $text = '' unless defined $text;
        $text_more = '' unless defined $text_more;
        my $filters = $obj->text_filters;
        push @$filters, '__default__' unless @$filters;
        $text = MT->apply_text_filters($text, $filters);
        $text_more = MT->apply_text_filters($text_more, $filters) if $text_more ne '';
        $text .= "\n\n<a href='" . $obj->permalink . "' target='_blank'>read more...</a>" if $text_more ne '';
    }

    $entry->content( MT::I18N::encode_text( $text, $enc, 'utf-8' ) );

    my @tags = $obj->tags;
    my $dc = XML::Atom::Namespace->new( dc => NS_DC );
    foreach my $tag (@tags) {
        $entry->add($dc, 'subject', MT::I18N::encode_text( $tag, $enc, 'utf-8' ) );
    }

    # CLIENT
    require XML::Atom::Client;
    my $api = XML::Atom::Client->new;
    $api->username( $config->{vox_username} );
    $api->password( $config->{vox_password} );

    # SEND
    if ( $new_post ) {
        my $edit_uri = $api->createEntry( $apilink, $entry )
            or return MT->log({
                message => $api->errstr,
            });
        # Save EditURI
        my @t = split /\s+/, ($obj->tangent_cache || '');
        push @t, $edit_uri;
        $obj->tangent_cache( join ' ', @t );
        $obj->save;
    } else {
        my $ret = $api->updateEntry( $apilink, $entry )
            or return MT->log({
                message => $api->errstr,
            });
    }

    return $obj;
}

#TODO: other API support
sub _find_apilink {
    my $self = shift;
    my ($uri) = @_;

    require XML::Atom::Feed;
    my $feed = XML::Atom::Feed->new(URI->new($uri));
    return undef unless $feed;
    my @links = $feed->link;
    for my $link (@links) {
        if ($link->rel eq 'service.post') {
            return $link->href;
        }
    }
    return undef;
}

# Since these settings are blog *and* user specific, automatically assign
# attach the user id to the scope element of all load/save/reset operations
# that operate on the blog scope.

sub load_config {
    my $plugin = shift;
    my $app = MT->instance;
    return unless $app->can('user');

    my ($param, $scope) = @_;
    $scope .= ':user:' . $app->user->id if $scope =~ m/^blog:/;
    $plugin->SUPER::load_config($param, $scope);
}

sub save_config {
    my $plugin = shift;
    my $app = MT->instance;
    return unless $app->can('user');

    my ($param, $scope) = @_;
    $scope .= ':user:' . $app->user->id if $scope =~ m/^blog:/;
    $plugin->SUPER::save_config($param, $scope);
}

sub reset_config {
    my $plugin = shift;
    my $app = MT->instance;
    return unless $app->can('user');
    my ($scope) = @_;
    $scope .= ':user:' . $app->user->id if $scope =~ m/^blog:/;
    $plugin->SUPER::reset_config($scope);
}

1;
