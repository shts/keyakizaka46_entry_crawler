
require 'eventmachine'
# URLにアクセスするためのライブラリを読み込む
require 'open-uri'
# HTMLをパースするためのライブラリを読み込む
require 'nokogiri'
# 日付ライブラリの読み込み
require "date"
# Parseライブラリの読み込み
require 'parse-ruby-client'

require "uri"

Parse.init :application_id => ENV['PARSE_APP_ID'],
           :api_key        => ENV['PARSE_API_KEY']

#OfficialSiteUrl = "http://blog.keyakizaka46.com/mob/news/diarKiji.php?site=k46&cd=member"
BaseUrl = "http://www.keyakizaka46.com"
BlogBaseUrl = "http://www.keyakizaka46.com/mob/news/diarKiji.php?cd=member&ct="
# TODO: デバッグ用本番はMember
MemberClassName = "Member"
EntryClassName = "Entry"

def parsepage key, loop=false

  page = Nokogiri::HTML(open(BlogBaseUrl + key))

  page.css('article').each do |article|

    data = {}
    data[:title] = normalize article.css('.box-ttl > h3').text
    data[:published] = normalize article.css('.box-bottom > ul > li')[0].text
    data[:published] = Parse::Date.new(data[:published])

    data[:article_url] = BaseUrl + article.css('.box-bottom > ul > li')[1].css('a')[0][:href]
    data[:article_url] = url_normalize data[:article_url]

    data[:image_url_list] = Array.new()
    article.css('.box-article').css('img').each do |img|
      data[:image_url_list].push(BaseUrl + img[:src])
    end

    yield(data) if block_given?
  end

  return if !loop
  puts "next page"

  page.css('.pager > ul > li').each do |li|
    parsepage BaseUrl + li.css('a')[0][:href] { |data|
      yield(data) if block_given?
    } if li.text == '>'
  end
end

def normalize str
  str.gsub(/(\r\n|\r|\n|\f)/,"").strip
end

def url_normalize url
  # before
  # http://www.keyakizaka46.com/mob/news/diarKijiShw.php?site=k46o&ima=0445&id=405&cd=member
  # after
  # http://www.keyakizaka46.com/mob/news/diarKijiShw.php?id=405&cd=member
  uri = URI.parse(url)
  q_array = URI::decode_www_form(uri.query)
  q_hash = Hash[q_array]
  "http://www.keyakizaka46.com/mob/news/diarKijiShw.php?id=#{q_hash['id']}&cd=member"
end

def save_data data, member, debug=false
  begin
    data[:member_id] = member['objectId']
    data[:member_key] = member['key']
    data[:member_name] = member['name_main']
    data[:member_image_url] = member['image_url']

    entry = Parse::Object.new(EntryClassName)
    data.each { |key, val|
      entry[key] = val
    }
    result = entry.save
    yield(result, data) if block_given?

  rescue Net::ReadTimeout => e
    sleep 5
    puts "retry : insert url -> #{data[:article_url]}"
    retry
  end
end

def push_notification result, data
  pushdata = { :action => "jp.shts.android.keyakifeed.BLOG_UPDATED",
           :_entryObjectId => result['objectId'],
           :_title => data[:title],
           :_article_url => data[:article_url],
           :_member_id => data[:member_id],
           :_member_name => data[:member_name],
           :_member_image_url => data[:member_image_url]
          }
  push = Parse::Push.new(pushdata)
  push.where = { :deviceType => "android" }
  puts pushdata
  puts push.save
end

def is_new? data
  Parse::Query.new(EntryClassName).tap do |q|
    q.eq("article_url", data[:article_url])
  end.get.first == nil
end

def get_all_member
  Parse::Query.new(MemberClassName).tap do |q|
    q.order_by = "key"
  end.get.each { |member| yield(member) if block_given? }
end

def get_all_entry
  get_all_member { |member|
    looop=true
    parsepage(member['key'], looop) { |data|
      save_data(data, member) if is_new? data
    }
  }
end

def routine_work
  get_all_member { |member|
    parsepage(member['key']) { |data|
      isnew = is_new?(data)
      puts "is new? #{isnew}"
      save_data(data, member) { |result, data|
        push_notification result, data
      } if is_new? data
    }
  }
end

all_entry = Parse::Query.new(EntryClassName).tap do |q|
  q.limit = 0
  q.count
end.get
if all_entry == nil || all_entry['count'] == 0
  puts "initialize"
  get_all_entry
end

EM.run do
  EM::PeriodicTimer.new(60) do
    puts "routine work"
    # 1ページのみ取得する
    routine_work
  end
end
