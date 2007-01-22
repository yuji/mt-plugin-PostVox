package MT::Plugin::PostVox;

use strict;
use warnings;

use MT 3.3;

use constant NS_DC => 'http://purl.org/dc/elements/1.1/';

use base 'MT::Plugin';
our $VERSION = '0.04';

my $plugin = MT::Plugin::PostVox->new({
    name            => 'Post to Vox',
    description     => 'Automatic cross-posting to Vox.',
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
    callbacks       => {
        'CMSPostSave.entry' => {
            priority => 9,
            code => \&hdlr_post_save
        },
        'APIPostSave.entry' => {
            priority => 9,
            code => \&hdlr_api_post_save
        },
        'MT::App::CMS::AppTemplateSource.entry_actions' => {
            priority => 9,
            code => \&add_input_field
        },
    },
});

MT->add_plugin($plugin);

sub add_input_field {
    my ($eh, $app, $tmpl) = @_;
    return unless $app->mode eq 'view';

    my $q = $app->param;
    my $blog_id = $q->param('blog_id');
    my $config = $plugin->get_config_hash('blog:'.$blog_id.':user:'.$app->user->id);
    return unless ( $config->{vox_username} || $config->{vox_password} );

    my $entry_id = $app->param('id');
    my $entry;
    if ($entry_id) {
        $entry = MT::Entry->load($entry_id, { cached_ok => 1 });
    }
    my $already_posted = $entry && (($entry->tangent_cache || '') =~ m!http://www.vox.com!);

    my $checked = '';
    $checked = "checked=\"checked\""
        if $config->{always_post} || $already_posted;
    my $label;
    if ($already_posted) {
        if ($entry->tangent_cache =~ m!(http://www.vox.com\S+)!i) {
            my $apilink = $1;
            if ($apilink =~ m!/asset_id=([a-e0-9]+)!) {
                my $asset_id = $1;
                $label = $plugin->translate('Update <a href="[_1]" target="_blank">Vox post</a>', "http://www.vox.com/compose/#id:$asset_id");
            }
        }
    }
    $label ||= '<MT_TRANS phrase="Cross-post to Vox">';
    $$tmpl =~ s!(<div class="button-bar">)!<p><input type="checkbox" id="post_to_vox" name="post_to_vox" $checked /> <label for="post_to_vox">$label</label></p>\n$1!is;
    1; 
}

sub hdlr_api_post_save {
    return $plugin->_cross_post(@_);
}

sub hdlr_post_save {
    my ($cb, $app, $obj, $orig) = @_;
    my $q = $app->param;
    return $obj unless $q->param('post_to_vox');
    
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

    require MT::Entry;
    return $obj if $obj->status != MT::Entry::RELEASE();

    # APILINK
    my $apilink = $config->{vox_apilink};
    my $new_post = 1;
    if ( $obj->tangent_cache && $obj->tangent_cache =~ m!(http://www.vox.com\S+)!i) {
        $apilink = $1;
        $new_post = 0;
    } elsif (!$apilink) {
        my $url = $config->{vox_url};
        if ( $url !~ m!rsd\.xml$! ) {
            if ( $url =~ m!/$! ) {
                $url .= 'rsd.xml';
            } else {
                $url .= '/rsd.xml';
            }
        }
        if ($url !~ m!^http://!i ) {
            $url = 'http://'.$url;
        }
        $apilink = $plugin->_find_apilink_rsd( $url );
        if ($apilink) {
            $config->{vox_apilink} = $apilink;
            $plugin->set_config_value('vox_apilink', $apilink, 'blog:'.$blog_id.':user:'.$app->user->id);
        }
        return $obj unless $apilink;
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
        #FIXME:Edit not support
        my $ret = $api->updateEntry( $apilink, $entry )
            or return MT->log({
                message => $api->errstr,
            });
    }

    return $obj;
}

#TODO: other API support
sub _find_apilink_rsd {
    my $self = shift;
    my ($rsd_uri) = @_;

    require XML::Simple;
    require LWP::Simple;
    my $xml_data = LWP::Simple::get($rsd_uri);
    my $xml     = XML::Simple::XMLin( $xml_data );
    my $apilink = $xml->{service}->{apis}->{api}->{Atom}->{apiLink};

    return 0, MT->log({
        message => "Couldn't retrieve 'apiLink' from $xml",
    }) unless $apilink;

    $apilink;
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
