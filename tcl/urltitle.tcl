#
# Fetch title of URLs in channels
#
# /set urltitle_enabled_channels #channel1 #channel2 ..
# to enable in those channels
#
# /set urltitle_ignored_nicks nick1 nick2 nick2 ..
# to not fetch titles of urls by these nicks
#

package require http
package require tls
package require htmlparse
package require idna

namespace eval urltitle {
	#variable useragent "Lynx/2.8.7rel.1 libwww-FM/2.14 SSL-MM/1.4.1 OpenSSL/0.9.8n"
	variable useragent "Tcl http client package 2.7.5"
	variable max_bytes 32768
	variable max_redirects 3

	settings_add_str "urltitle_enabled_channels" ""
	settings_add_str "urltitle_ignored_nicks" ""

	signal_add msg_pub "*" urltitle::urltitle

	::http::register https 443 ::tls::socket

	variable debug 0
}

proc urltitle::log {msg} {
	if {!$urltitle::debug} {
		return
	}
	irssi_print "urltitle: $msg"
}

proc urltitle::urltitle {server nick uhost chan msg} {
	if {![str_in_settings_str urltitle_enabled_channels $chan]} {
		return
	}

	if {[str_in_settings_str urltitle_ignored_nicks $nick]} {
		return
	}

	set url [urltitle::recognise_url $msg]
	if {$url == ""} {
		return
	}

	urltitle::geturl $url $server $chan 0
}

# Breaks an absolute URL into 3 pieces:
# prefix/protocol: e.g. http://, https//
# domain: e.g. everything up to the first /, if it exists
# rest: everything after the first /, if exists
proc urltitle::split_url {absolute_url} {
	if {![regexp -- {(https?://)([^/]*)/?(.*)} $absolute_url -> prefix domain rest]} {
		error "urltitle error: parse problem: $absolute_url"
	}
	set domain [idna::domain_toascii $domain]

	# from http-title.tcl by Pixelz. Avoids urls that will be treated as
	# a flag
	if {[string index $domain 0] eq "-"} {
		error "urltitle error: Invalid URL: domain looks like a flag"
	}
	return [list $prefix $domain $rest]
}

# Attempt to recognise potential_url as an actual url in form of http[s]://...
# Returns blank if unsuccessful
proc urltitle::recognise_url {potential_url} {
	set full_url []
	if {[regexp -nocase -- {(https?://\S+)} $potential_url -> url]} {
		set full_url $url
	} elseif {[regexp -nocase -- {(www\.\S+)} $potential_url -> url]} {
		set full_url "http://${url}"
	}

	if {$full_url == ""} {
		return ""
	}

	lassign [urltitle::split_url $full_url] prefix domain rest

	return "${prefix}${domain}/${rest}"
}

proc urltitle::extract_title {data} {
	if {[regexp -nocase -- {<title>(.*?)</title>} $data -> title]} {
		set title [regsub -all -- {\s+} $title " "]
		return [htmlparse::mapEscapes $title]
	}
	return ""
}

proc urltitle::geturl {url server chan redirect_count} {
	urltitle::log "geturl: Trying to get URL: $url"
	if {$redirect_count > $urltitle::max_redirects} {
		return
	}
	http::config -useragent $urltitle::useragent
	set token [http::geturl $url -blocksize $urltitle::max_bytes -timeout 10000 \
		-progress urltitle::http_progress -command "urltitle::http_done $server $chan $redirect_count"]
}

# stop after max_bytes
proc urltitle::http_progress {token total current} {
	if {$current >= $urltitle::max_bytes} {
		http::reset $token
	}
}

proc urltitle::http_done {server chan redirect_count token} {
	# Get state array out of token
	upvar #0 $token state
	# Get the URL out of the state array. We could pass it via the
	# callback but issues with variable substitution if URL contains what
	# appears to be variables?
	set url $state(url)
	set data [http::data $token]
	set code [http::ncode $token]
	set meta [http::meta $token]
	urltitle::log "http_done: trying to get charset"
	set charset [urltitle::get_charset $token]
	if {$urltitle::debug} {
		#irssi_print "http_done: data ${data}"
		irssi_print "http_done: code ${code}"
		irssi_print "http_done: meta ${meta}"
		irssi_print "http_done: got charset: $charset"
	}
	http::cleanup $token

	# Follow redirects for some 30* codes
	if {[regexp -- {30[01237]} $code]} {
		# Location may not be an absolute URL
		set new_url [urltitle::make_absolute_url $url [dict get $meta Location]]
		urltitle::geturl $new_url $server $chan [incr redirect_count]
	} else {
		set data [encoding convertfrom $charset $data]
		set title [extract_title $data]
		if {$title != ""} {
			putchan $server $chan "\002[string trim $title]"
		}
	}
}

# Ensure we return an absolute URL
# new_target is the Location given by a redirect. This may be an absolute
# url, or it may be relative
# If it's relative, use old_url
proc urltitle::make_absolute_url {old_url new_target} {
	# First check if we've been given an absolute URL
	set absolute_url [urltitle::recognise_url $new_target]
	if {$absolute_url != ""} {
		return $absolute_url
	}

	# Otherwise it must be a relative URL
	lassign [urltitle::split_url $old_url] prefix domain rest

	# Take everything up to the last / from rest
	if {[regexp -- {(\S+)/} $rest -> rest_prefix]} {
		set new_url "${prefix}${domain}/${rest_prefix}/${new_target}"

	# Otherwise there was no / in rest, so at top level
	} else {
		set new_url "${prefix}${domain}/${new_target}"
	}

	urltitle::log "make_absolute_url: prefix: $prefix domain $domain rest $rest old_url $old_url new_url $new_url"

	return $new_url
}

# @param ::http token
#
# @return string charset. "" if not found.
#
# look for a charset in the Content-Type header.
proc urltitle::get_charset_from_headers {token} {
	urltitle::log "get_charset_from_headers: trying to get charset"
	set meta [::http::meta $token]

	# does the content-type key exist?
	if {![dict exists $meta Content-Type]} {
		urltitle::log "get_charset_from_headers: no content-type found"
		return ""
	}
	set content_type [dict get $meta Content-Type]

	# try to retrieve charset
	set re {charset="?(.*?)"?;?}
	set res [regexp -nocase -- $re $content_type m charset]
	if {!$res} {
		urltitle::log "get_charset_from_headers: no charset found"
		return ""
	}
	urltitle::log "get_charset_from_headers: found charset: $charset"
	return $charset
}

# @param ::http token
#
# @return string charset. "" if not found.
#
# look for a charset in the html <meta/> tag.
proc urltitle::get_charset_from_body {token} {
	urltitle::log "get_charset_from_body: trying to get charset"
	set data [::http::data $token]

	set re {<meta[^>]+?charset=(\S+)['"].*?>}
	set res [regexp -nocase -- $re $data m charset]
	if {!$res} {
		urltitle::log "get_charset_from_body: no charset found"
		return ""
	}

	urltitle::log "get_charset_from_body: found charset: $charset"
	return $charset
}

# @param string charset   charset found from examining result
#
# @return string charset
#
# try translate the charset so as to be recognized as a tcl charset.
# some may be specified by the result/document that are not an
# exact match to tcl charset names.
proc urltitle::translate_charset {charset} {
	urltitle::log "translate_charset: got charset $charset"
	set charset [string tolower $charset]
	# iso-8859-1 must be changed to iso8859-1
	regsub -- {iso-} $charset iso charset
	# shift_jis -> shiftjis
	regsub -- {shift_} $charset shift charset
	urltitle::log "translate_charset: have charset $charset after translate"
	return $charset
}

# @param ::http token
#
# @return string charset
#
# try to get the charset of the requested document.
# first try http headers, then meta in body.
# fall back to iso8859-1 if we don't find one.
proc urltitle::get_charset {token} {
	# the charset from the Content-Type meta-data value.
	set charset [urltitle::get_charset_from_headers $token]
	if {$charset != ""} {
		return [urltitle::translate_charset $charset]
	}

	# no charset given in http header. try to get from the meta tag in the body.
	set charset [urltitle::get_charset_from_body $token]
	if {$charset != ""} {
		return [urltitle::translate_charset $charset]
	}

	# default to iso8859-1.
	set charset iso8859-1
	return [urltitle::translate_charset $charset]
}

irssi_print "urltitle.tcl loaded"
