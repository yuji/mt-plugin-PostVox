package MT::Plugin::PostVox;

use strict;
use warnings;
use MT 3.3;

use constant NS_DC => 'http://purl.org/dc/elements/1.1/';
use base 'MT::Plugin';
our $VERSION = '0.01';

my $plugin = MT::Plugin::PostVox->new({
    name            => 'Post to the Vox',
    description     => 'Cross post to the Vox',
    author_name     => 'Six Apart, Ltd.',
    author_link     => 'http://www.sixapart.com/',
    version         => $VERSION,
    settings        => new MT::PluginSettings([
        ['vox_username'],
        ['vox_password'],
        ['vox_url'],
        ['always_post']
    ]),
    config_template => 'config.tmpl',
    callbacks       => {
        'CMSPostSave.entry' => {
            priority => 9,
            code => \&hdlr_post_save
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
    my $q = $app->param;
    my $blog_id = $q->param('blog_id');
    my $config = $plugin->get_config_hash('blog:'.$blog_id);
    my $checked = "checked" if $config->{always_post};

    $$tmpl =~ s!(<div class="button-bar">)!<p><input type="checkbox" name="post_to_vox" $checked/> <MT_TRANS phrase="Cross post to the Vox"></p>\n$1!is;
    1; 
}

sub hdlr_post_save {
    my ($cb, $app, $obj, $orig) = @_;
    my $q = $app->param;
    my $blog_id = $q->param('blog_id');
    my $config = $plugin->get_config_hash('blog:'.$blog_id);

    return $obj unless ( $config->{vox_username} || $config->{vox_password} || $config->{vox_url} );
    return $obj if $obj->status != MT::Entry::RELEASE();
    return $obj unless $q->param('post_to_vox');

    # APILINK
    my $apilink;
    my $new_post = 1;
    if ( $obj->keywords && $obj->keywords =~ m!http://www.vox.com!i) {
        $apilink = $obj->keywords;
        $new_post = 0;
    } else {
        my $url = $config->{vox_url};
        if ( $url !~ m!rsd\.xml$!i ) {
            if ( $url =~ m!/$!i ) {
                $url .= 'rsd.xml';
            } else {
                $url .= '/rsd.xml';
            }
        }
        if ($url !~ m!^http://!i ) {
            $url = 'http://'.$url;
        }
        $apilink = $plugin->_find_apilink_rsd( $url );
        return $obj unless $apilink;
    }

    # ENTRY
    use XML::Atom::Entry;
    my $enc = MT->instance->config('PublishCharset') || undef;
    my $entry = XML::Atom::Entry->new;
    $entry->title( MT::I18N::encode_text( $obj->title , 'utf-8', $enc ) );
    $entry->content( MT::I18N::encode_text( $obj->text, 'utf-8', $enc ) );

    my @tags = $plugin->_get_entry_tags( $obj );
    my $dc = XML::Atom::Namespace->new( dc => NS_DC );
    foreach my $tag (@tags) {
        $entry->add($dc, 'subject', MT::I18N::encode_text( $tag->name, 'utf-8', $enc ) );
    }

    # CLIENT
    use XML::Atom::Client;
    my $api = XML::Atom::Client->new;
    $api->username( $config->{vox_username} );
    $api->password( $config->{vox_password} );

    # SEND
    if ( $new_post ) {
        my $edit_uri = $api->createEntry( $apilink, $entry )
            or return $plugin->log({
                message => $api->errstr,
            });

        # Save EditURI
        $obj->keywords( $edit_uri );
        $obj->save;
    } else {
        #FIXME:Edit not support
        my $ret = $api->updateEntry( $apilink, $entry )
            or return $plugin->log({
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

    return 0, $plugin->log({
        message => "Couldn't retrieve 'apiLink' from $xml",
    }) unless $apilink;

    $apilink;
}

sub _get_entry_tags {
    my $self = shift;
    my($entry) = @_;

    return '' unless $entry;

    require MT::ObjectTag;
    require MT::Entry;
    require MT::Tag;
    my $iter = MT::Tag->load_iter(undef, { 'sort' => 'name',
        join => ['MT::ObjectTag', 'tag_id',
        { object_id => $entry->id, blog_id => $entry->blog_id, object_datasource => MT::Entry->datasource }, { unique => 1 } ]});
    my @tags;
    while (my $tag = $iter->()) {
        next if $tag->is_private;
        push @tags, $tag;
    }
    return @tags;
}

1;

