#!/usr/bin/env ruby

# Copyright 2015 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'rubygems'
require 'octokit'
require 'yaml'
require 'xml'
require 'xslt'
require_relative 'github-sync/init-database'
require_relative 'github-sync/sync'
require_relative 'github-pull/pull_source'
require_relative 'review-repos/reporter_runner'
require_relative 'generate-dashboard/generate-dashboard-xml'
require 'optparse'

class DashboardContext < Hash

  attr_reader :feedback, :dashboard_config, :client

  def initialize(feedback, dashboard_config, client)
    @feedback=feedback
    @dashboard_config=dashboard_config
    @client=client
  end

end

options = {}

optparse = OptionParser.new do |opts|
  options[:ghconfig] = nil
  opts.on( '-g', '--ghconfig FILE', 'Provide GitHub Access Token Configuation File' ) do |file|
    options[:ghconfig] = file
  end
  options[:quiet] = false
  opts.on( '-q', '--quiet', 'Silence the script' ) do
    options[:quiet] = true
  end
  options[:light] = false
  opts.on( '-l', '--light', 'Run in light mode, pull minimum of data' ) do
    options[:light] = true
  end
end
optparse.parse!

# GitHub setup
if(ENV['GH_ACCESS_TOKEN'])
  access_token=ENV['GH_ACCESS_TOKEN']
elsif(options[:ghconfig])
  config_file = options[:ghconfig]
  config = YAML.load(File.read(config_file))
  access_token = config['github']['access_token']
else
  puts "ERROR: Need a GitHub access token, either via environment variable (GH_ACCESS_TOKEN) or configuration file. "
  puts "Usages: \n    GH_ACCESS_TOKEN=... #{$0} <dashboard-config> [optional-phase]\n    #{$0} --ghconfig <file> <dashboard-config> [optional-phase]"
  exit
end

Octokit.auto_paginate = true
client = Octokit::Client.new :access_token => access_token, :accept => 'application/vnd.github.moondragon+json' 

# Dashboard configuration
config_file = ARGV[0]
config = YAML.load(File.read(config_file))
dashboard_config = config['dashboard']
data_directory = dashboard_config['data-directory']
www_directory = dashboard_config['www-directory']
organizations = dashboard_config['organizations']

unless(File.exists?(data_directory))
  Dir.mkdir(data_directory)
end

if(options[:light] and ARGV[1])
  puts "Light mode does not allow specific phases to be called. "
  exit
end

# TODO: Implement github-sync and generate-dashboard as aliases?
allPhases=['init-database', 'github-sync/metadata', 'github-sync/commits', 'github-sync/events', 'github-sync/issues', 'github-sync/issue-comments', 'github-sync/releases', 'github-sync/user-mapping', 'github-sync/reporting', 'pull-source', 'review-source', 'generate-dashboard/xml', 'generate-dashboard/merge', 'generate-dashboard/teams-xml', 'generate-dashboard/xslt']
legitPhases=allPhases + ['github-sync', 'generate-dashboard']

if(ARGV[1])
  run_list=ARGV[1..-1]
  if(run_list.include?('init-database'))
    if(File.exists?(File.join(data_directory, 'db', 'gh-sync.db')))
      context.feedback.puts "ERROR: Will not initialize over the top of an existing database file. Please remove the database file if reset desired. "
      exit
    end
  end
elsif(options[:light])
  legitPhases=['init-database', 'github-sync/metadata', 'github-sync/reporting', 'generate-dashboard', 'generate-dashboard/xml', 'generate-dashboard/merge', 'generate-dashboard/teams-xml', 'generate-dashboard/xslt']
else
  run_list=allPhases
end

# check all phases are legit
run_list.each do |phase|
  unless( legitPhases.include?(phase))
    puts "No such phase: #{phase}."
    exit
  end
end

# Quiet mode or verbose
feedback=$stdout
if(options[:quiet])
  feedback=File.open(File::NULL, "w")
else
  $stdout.sync = true
end

context=DashboardContext.new(feedback, dashboard_config, client)
context[:START_TIME]=DateTime.now

context[:START_RATE_LIMIT]=client.rate_limit.remaining
unless(options[:quiet])
  context.feedback.puts "Remaining GitHub Calls: #{context[:START_RATE_LIMIT]}"
end
 
# State to make output cleaner
printed_gh_sync=false
printed_gen_dash=false

run_list.each do |phase|
  if(phase=='init-database')
    unless(File.exists?(File.join(data_directory, 'db', 'gh-sync.db')))
      context.feedback.puts "init-database"
      init_database(context)
    end
  end

  if(phase.start_with?('github-sync'))
    unless(printed_gh_sync)
      context.feedback.puts "github-sync"
      printed_gh_sync=true
    end
    github_sync(context, phase=='github-sync' ? nil : phase)
  end
  if(phase=='pull-source')
    context.feedback.puts "pull-source"
    pull_source(context)
  end
  if(phase=='review-source')
    context.feedback.puts "review-source"
    review_source(context)
  end

  context[:END_RATE_LIMIT]=client.rate_limit.remaining
  context[:USED_RATE_LIMIT]=context[:START_RATE_LIMIT]-context[:END_RATE_LIMIT]
  # TODO: This isn't perfect, you could flip over the hour, but use lots of rate_limit and not be negative
  if(context[:USED_RATE_LIMIT] < 0)
    context[:USED_RATE_LIMIT]+=5000
  end

  if(phase.start_with?('generate-dashboard'))
    unless(printed_gen_dash)
      context.feedback.puts "generate-dashboard"
       printed_gen_dash=true
    end

    if(phase=='generate-dashboard' or phase=='generate-dashboard/xml')
      context.feedback.puts " xml"
      generate_dashboard_xml(context)
    end

    if(organizations.length > 1)
      if(phase=='generate-dashboard' or phase=='generate-dashboard/merge')
        context.feedback.puts " merge"
        merge_dashboard_xml(context)
      end
    end

    if(phase=='generate-dashboard' or phase=='generate-dashboard/teams-xml')
      context.feedback.puts " teams-xml"
      generate_team_xml(context)
    end

    if(phase=='generate-dashboard' or phase=='generate-dashboard/xslt')
      unless(File.exists?(www_directory))
        Dir.mkdir(www_directory)
      end

      context.feedback.print " xslt\n  "
      Dir.glob("#{data_directory}/dash-xml/*.xml").each do |inputFile|
        outputFile=File.basename(inputFile, ".xml")

        stylesheet = LibXSLT::XSLT::Stylesheet.new( LibXML::XML::Document.file(File.join( File.dirname(__FILE__), 'generate-dashboard', 'style', 'dashboardToHtml.xslt') ) )
        xml_doc = LibXML::XML::Document.file(inputFile)
        html = stylesheet.apply(xml_doc)

        htmlFile = File.new("#{www_directory}/#{outputFile}.html", 'w')
        htmlFile.write(html)
        htmlFile.close
        context.feedback.print "."
      end
      context.feedback.print "\n"

      if(organizations.length > 1)
        context.feedback.puts " AllOrgs"

        stylesheet = LibXSLT::XSLT::Stylesheet.new( LibXML::XML::Document.file(File.join( File.dirname(__FILE__), 'generate-dashboard', 'style', 'dashboardToHtml.xslt') ) )
        xml_doc = LibXML::XML::Document.file("#{data_directory}/dash-xml/AllOrgs.xml")
        html = stylesheet.apply(xml_doc)

        htmlFile = File.new("#{www_directory}/AllOrgs.html", 'w')
        htmlFile.write(html)
        htmlFile.close
      end

      context.feedback.puts "\nSee HTML in #{www_directory}/ for dashboard."
    end
  end
end

unless(options[:quiet])
  context.feedback.puts "Remaining GitHub Calls: #{client.rate_limit.remaining}"
end
