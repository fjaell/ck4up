#! /usr/bin/env ruby
#
# ck4up
# 
# Copyright (c) Juergen Daubert <jue@crux.nu>
# Version 1.4  2014-12-23
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, 
# USA.
#

require 'net/https'
require 'net/ftp'
require 'digest'
require 'gdbm'
require 'getoptlong'
require 'timeout'
require 'resolv-replace'


DefaultConfig = ENV['HOME'] + '/.ck4up/ck4up.conf'
HttpProxy     = ENV['HTTP_PROXY'] || ENV['http_proxy']

Threads_max   = 20    # Number of parallel threads
Ftp_passive   = true  # use passive mode for ftp
Ftp_time      = 20    # timeout in seconds for ftp requests



def usage()
	print <<EOS
Usage: ck4up [options] [exp ...]
Options: 
 -d,      --debug        debug mode, print fetched pages
 -h,      --help         print this help message
 -k,      --keep         keep md5 values, don't change database
 -c,      --cleandb      clean unused keys from database
 -p,      --parseonly    process and print configuration file
 -v,      --verbose      verbose mode, show unchanged pages
 -f file, --config file  use configuration from file, see ck4up(1)
 exp                     check only configuration lines matching exp  
EOS
	exit
end


def parse_options()
	options = {}
	begin
		valid_options = GetoptLong.new(
			["--debug",     "-d", GetoptLong::NO_ARGUMENT],
			["--keep",      "-k", GetoptLong::NO_ARGUMENT],
			["--verbose",   "-v", GetoptLong::NO_ARGUMENT],
			["--cleandb",   "-c", GetoptLong::NO_ARGUMENT],
			["--help",      "-h", GetoptLong::NO_ARGUMENT],
			["--parseonly", "-p", GetoptLong::NO_ARGUMENT],
			["--config",    "-f", GetoptLong::REQUIRED_ARGUMENT])
		valid_options.each do |opt,arg|
			case opt
				when "--debug"     then options["debug"] = true
				when "--keep"      then options["keep"] = true
				when "--verbose"   then options["verbose"] = true
				when "--cleandb"   then options["cleandb"] = true
				when "--parseonly" then options["parseonly"] = true
				when "--config"    then options["config"] = arg
				when "--help"      then usage
			end
		end
	rescue
		exit -1
	end

	if ! $Config = options["config"]
		$Config = DefaultConfig
	end
	$Database = $Config.sub(/\.[^.]*$/,"") + ".dbm"

	return options
end


def print_result(io,a,b,*c)
	io.printf("%-.15s %-s %-6s %s\n", a,"."*([15-a.length,0].max),b,c.join(" "))
end


class Parser
	def initialize(file)
		@file = file
		@macro = {}
		Parser.exist_config(@file)
	end

	def Parser.exist_config(file)
		if not FileTest::exist?(file)
			puts "Error: Configuration file #{file} not found !"
			exit -1
		end
	end

	def parse
		File.read(@file).each_line do |row|
			yield replace_macros(row)
		end
	end

	def replace_macros(line)
		case line
			when /^@\w*@/
				@macro[line.split[0]] = line.split[1..-1].join(' ')
				return false
			when /^[a-zA-Z]/
				expand_macros(line)
				return line.gsub('@NAME@',line.split[0])
			else
				return false
		end
	end

	def expand_macros(line)
	 	begin
			@macro.each { |k,v| expand_macros(line) if line.gsub!(k,v) }
		rescue => error
			print_result(STDERR,line.split[0],'fatal error:',error.to_s.strip)
			exit -1
		end
	end
end


class CheckUp

	SAME = 0
	DIFF = 1
	NEW  = 2

	def CheckUp.set_http_proxy(proxy)
		@@proxy_host, @@proxy_port = nil
		return if not proxy
		p = URI.parse(proxy)
		if (p.host && p.port)
			@@proxy_host = p.host
			@@proxy_port = p.port
		else
			puts "Warning: invalid HTTP_PROXY environment variable -> " + proxy
		end
	end

	def CheckUp.set_db(db,access)
		@@db_readonly = access
		if FileTest::exist?(db)
			@@db = GDBM.open(db)
		else
			puts "Info: Creating new database #{db}"
			@@db = GDBM.new(db)
		end
		at_exit { @@db.close }
	end

	def check(name,type,url=nil,regexp=nil)
		@name = name
		@url=url
		case type
			when 'md5' then check_md5(regexp)
			else raise "Unknown type: #{type}"
		end
	end

	def check_md5(reg)
		page = fetch_page
		page = page.scan(/#{reg}/).uniq if reg
		puts page if Opts["debug"]
		page = page.join if page.is_a?(Array)
		raise "empty result" if page == ""
		save_md5(Digest::MD5.hexdigest(page))
	end

	def save_md5(md5)
		if md5 == @@db[@name]
			return SAME
		else
			@@db[@name] ? res = DIFF : res = NEW
			@@db[@name] = md5 if not @@db_readonly
			return res
		end
	end

	def clean_db(keeplist)
		active = Hash.new
		for k in keeplist
			active[k] = @@db[k]
		end

		oldCount = @@db.size
		@@db.clear

		active.each_key do |key|
			@@db[key] = active[key] if active[key]
		end

		return oldCount - @@db.size
	end

	def fetch_page()
		begin
			uri = URI.parse(@url)
			case uri.scheme
				when "http", "https"
					fetch_page_http(uri)
				when "ftp"
					fetch_page_ftp(uri)
				else
					raise "wrong url syntax #{@url}"
			end
		rescue Exception => err
			raise err.to_s
		end
	end

	def fetch_page_http(uri, limit = 10)
		if limit.zero?
			raise ArgumentError, "HTTP redirect too deep"
		end

		http = Net::HTTP.new(uri.host, uri.port, @@proxy_host, @@proxy_port)
		if uri.scheme == "https"
			http.use_ssl = true
			http.verify_mode = OpenSSL::SSL::VERIFY_NONE
		end
		response = http.request_get(uri.request_uri)

		case response
			when Net::HTTPSuccess
				return response.body
			when Net::HTTPRedirection
				loc = URI.parse(response['Location'])
				uri = loc if loc.scheme == "http" or loc.scheme == "https"
				fetch_page_http(uri, limit - 1)
			else
				response.error!
		end
	end

	def fetch_page_ftp(uri)
		Timeout::timeout(Ftp_time) do
			ftp = Net::FTP.new(uri.host)
			ftp.passive = true if Ftp_passive
			ftp.login("anonymous", "ck4up@example.com")
			ftp.chdir(uri.path)
			res = ftp.list.join("\n")
			ftp.close
			return res
		end
	end

end



def do_parse()
	Parser.new($Config).parse do |line|
		if line and line.index(/#{ARGV.join('|')}/)
			puts line
		end
	end
end

def do_cleanup()
	checkUp = CheckUp.new
	keeplist = []

	Parser.new($Config).parse do |line|
		if line
			n,t,u,r = line.split
			keeplist.push(n)
		end
	end

	count = checkUp.clean_db(keeplist)
	printf "Removed %d records\n", count
end

def do_check()
	threads = []

	Parser.new($Config).parse do |line|

		while Thread.list.size > Threads_max; sleep 1; end

		if line and line.index(/#{ARGV.join('|')}/)
			n,t,u,r = line.split
			threads << Thread.new(n,t,u,r) do |name,type,url,regexp|
				begin
					result = CheckUp.new.check(name,type,url,regexp)
					case result
						when CheckUp::SAME
							print_result(STDOUT,name,'ok') if Opts["verbose"]
						when CheckUp::NEW
							print_result(STDOUT,name,'new: ',url)
						else
							print_result(STDOUT,name,'diff:',url)
					end
				rescue => error
					print_result(STDERR,name,'error:',error.to_s.strip)
				end
			end
		end
	end

	threads.each { |t| t.join }
end


trap('INT') { puts; exit }

Opts = parse_options
Parser.exist_config($Config)
CheckUp.set_db($Database,Opts["keep"])
CheckUp.set_http_proxy(HttpProxy)

if Opts["cleandb"]
	do_cleanup
	exit
elsif Opts["parseonly"]
	do_parse
	exit
else
	do_check
end


# vim:ts=2 sw=2 noexpandtab
# End of file
