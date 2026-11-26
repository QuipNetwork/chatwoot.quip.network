# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run inside the app image (it has Ruby and minitest), from the repo root:
#   docker run --rm --network none -v "$PWD/images/app:/q:ro" --entrypoint ruby \
#     <app image> /q/test/quip_email_reply_test.rb
require 'minitest/autorun'
require_relative '../quip_email_reply'

class QuipEmailReplyTest < Minitest::Test
  FULL = "Still broken.\n\nSent with Proton Mail secure email.\n\nOn Wed, X wrote:\n\n> earlier".freeze

  def part(quoted, reply: FULL) = { full: reply, reply: reply, quoted: quoted }

  def test_text_part_gives_the_trimmed_reply
    assert_equal 'Still broken.', QuipEmailReply.content(part('Still broken.'), part('from html'))
  end

  def test_html_part_is_used_when_there_is_no_text_part
    assert_equal 'from html', QuipEmailReply.content({}, part('from html'))
  end

  def test_nil_text_part_falls_through_to_html
    assert_equal 'from html', QuipEmailReply.content(nil, part('from html'))
  end

  def test_no_parts_keeps_upstream
    assert_nil QuipEmailReply.content({}, {})
    assert_nil QuipEmailReply.content(nil, nil)
  end

  # A reply that is all quote trims to nothing; upstream's full text is better
  # than an empty message.
  def test_empty_trim_keeps_upstream
    assert_nil QuipEmailReply.content(part(''), {})
    assert_nil QuipEmailReply.content(part("  \n "), {})
  end

  # Upstream picks the text part whenever it exists; so do we, even when its
  # trim is empty, so the HTML part never overrides it.
  def test_empty_text_trim_does_not_switch_to_html
    assert_nil QuipEmailReply.content(part(''), part('from html'))
  end

  def test_missing_quoted_key_keeps_upstream
    assert_nil QuipEmailReply.content({ full: FULL, reply: FULL }, {})
  end
end
