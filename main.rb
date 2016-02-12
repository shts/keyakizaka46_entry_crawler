
# view-source:http://blog.keyakizaka46.com/mob/news/diarKiji.php?site=k46&cd=member
#view-source:http://blog.keyakizaka46.com/mob/news/diarKiji.php?site=k46&ima=2653&cd=member&ct=01
# プログラムを定期実行するためのライブラリを読み込む
require 'eventmachine'
# URLにアクセスするためのライブラリを読み込む
require 'open-uri'
# HTMLをパースするためのライブラリを読み込む
require 'nokogiri'
# 日付ライブラリの読み込み
require "date"
# Parseライブラリの読み込み
require 'parse-ruby-client'
# TODO: Windowsのみで発生する証明書問題によりSSL認証エラーの暫定回避策
#ENV['SSL_CERT_FILE'] = File.expand_path('C:\rumix\ruby\2.1\i386-mingw32\lib\ruby\2.1.0\rubygems\ssl_certs\cert.pem')
# TODO: デバッグ用 KEY
Parse.init :application_id => ENV['PARSE_APP_ID'],
           :api_key        => ENV['PARSE_API_KEY']

OfficialSiteUrl = "http://blog.keyakizaka46.com/mob/news/diarKiji.php?site=k46&cd=member"
BaseUrl = "http://blog.keyakizaka46.com"
MemberClassName = "Member"
EntryClassName = "Entry"

def parsepage(url, need_loop)
  # http://blog.keyakizaka46.com/mob/news/diarKiji.php?site=k46&ima=2653&cd=member&ct=01
  page = Nokogiri::HTML(open(url, 'User-Agent' => 'ruby'))
  page.css('div.kiji').each do |kiji|
    data = {}
    # title
    data[:yearmonth] =  kiji.css('td.date').css('span.kiji_yearmonth')[0].text
    data[:day] =  kiji.css('td.date').css('span.kiji_day')[0].text
    data[:week] =  kiji.css('td.date').css('span.kiji_week')[0].text

    data[:author] =  kiji.css('td.title').css('span.kiji_member')[0].text
    data[:title] =  kiji.css('td.title').css('span.kiji_title')[0].text
    data[:body] = kiji.css('div.kiji_body')

    data[:image_url_list] = Array.new()
    data[:body].css('img').each do |img|
      if img[:src].empty? then
        # do nothing
      else
        image_url = BaseUrl + img[:src]
        data[:body] = "#{data[:body]}".gsub(img[:src], image_url)
        data[:image_url_list].push(image_url)
      end
    end

    published = DateTime.parse(kiji.css('div.kiji_foot')[0].text.gsub(/(\r\n|\r|\n|\f)/,""))
    data[:published] = Parse::Date.new(published)

    yield(data) if block_given?
  end
  return if !need_loop
  if page.css('li.next').css('a')[0] != nil then
    puts "nextpage"
    next_url = page.css('li.next').css('a')[0][:href]
    parsepage("#{BaseUrl}#{next_url}", true) { |data|
      yield(data) if block_given?
    } if next_url != nil
  else
    puts "finish"
  end
end

def is_new?(author, published)
  Parse::Query.new(EntryClassName).tap do |q|
    q.eq("author", author)
    q.eq("published", published)
  end.get.first == nil
end

def push(data)
  push = Parse::Push.new(data)
  push.where = { :deviceType => "android" }
  puts push.save
end

def crawlpage(need_loop)
  allmember = Parse::Query.new(MemberClassName).tap do |q|
    q.order_by = "blog_url"
  end.get
  allmember.each do |member|
    parsepage(member['blog_url'], need_loop) { |data|
      if is_new?(data[:author], data[:published]) then
        begin
          entry = Parse::Object.new(EntryClassName)
          entry['author_id'] = member['objectId']
          entry['author_image_url'] = member['image_url']
          data.each { |key, val|
            entry[key] = val
          }
          result = entry.save
          puts result

          objectId = result['objectId']
          title = data[:title]
          author = data[:author]
          author_id = entry['author_id']
          author_image_url = entry['author_image_url']

          data = { :action => "jp.shts.android.keyakifeed.BLOG_UPDATED",
                   :_entryObjectId => objectId,
                   :_title => title,
                   :_author => author,
                   :_author_id => author_id,
                   :_author_image_url => author_image_url
                  }
          yield(data) if block_given?
        rescue Net::ReadTimeout => e
          sleep 5
          puts "retry : insert url -> #{member['blog_url']}"
          retry
        end
      else
        puts "already exist entry"
      end
    }
  end
end

def routine_work
end

all_entry = Parse::Query.new(EntryClassName).tap do |q|
  q.limit = 0
  q.count
end.get
if all_entry == nil || all_entry['count'] == 0
  puts "initialize"
  crawlpage(true)
end

EM.run do
  EM::PeriodicTimer.new(60) do
    puts "routine work"
    # 1ページのみ取得する
    crawlpage(false) { |data|
      push(data)
    }
  end
end
