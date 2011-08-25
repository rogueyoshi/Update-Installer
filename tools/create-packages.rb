#!/usr/bin/ruby

require 'rubygems'
require 'find'
require 'json'
require 'rexml/document'
require 'optparse'

# syntax:
#
# create-packages.rb <input directory> <package map> <output directory>
#
#  Takes the set of files that make up a release and splits them up into
#  a set of .zip packages
#
#  Outputs:
#
#   <output-dir>/$PACKAGE_NAME.zip
#     These are packages containing the files in this version of the software.
#
#   <output-dir>/file_list.xml
#     This file lists all the files contained in this version of the software and
#     the packages which they are contained in.
#

# Represents a group of updates in a release
class UpdateScriptPackage
	# name - The name of the package (without any extension)
	# hash - The SHA-1 hash of the package
	# size - The size of the package in bytes
	attr_reader :name,:hash,:size
	attr_writer :name,:hash,:size
end

# Represents a single file in a release
class UpdateScriptFile
	# path - The path of the file relative to the installation directory
	# hash - The SHA-1 hash of the file
	# permissions - The permissions of the file expressed using
	#               flags from the QFile::Permission enum in Qt
	# size - The size of the file in bytes
	# package - The name of the package containing this file
	attr_reader :path,:hash,:permissions,:size,:package,:target
	attr_writer :path,:hash,:permissions,:size,:package,:target
end

# Utility method - convert a hash map to an REXML element
#
# Hash keys are converted to elements and hash values either
# to text contents or child elements (if the value is a Hash)
#
# 'root' - the root REXML::Element
# 'map' - a hash mapping element names to text contents or
#         hash maps
#
def hash_to_xml(root,map)
	map.each do |key,value|
		element = REXML::Element.new(key)
		if value.instance_of?(String)
			element.text = value
		elsif value.instance_of?(Hash)
			hash_to_xml(element,value)
		elsif !value.nil?
			raise "Unsupported value type #{value.class}"
		end
		root.add_element element
	end
	return root
end

def strip_prefix(string,prefix)
	if (!string.start_with?(prefix))
		raise "String does not start with prefix"
	end
	return string.sub(prefix,"")
end

class UpdateScriptGenerator
	def initialize(input_dir,output_dir, file_list, package_file_map)
		# List of files to install in this version
		@files_to_install = []
		file_list.each do |path|
			file = UpdateScriptFile.new
			file.path = strip_prefix(path,input_dir)
			
			if (File.symlink?(path))
				file.target = File.readlink(path)
			else
				file.hash = file_sha1(path)
				file.permissions = get_file_permissions(path)
				file.size = File.size(path)
				package_file_map.each do |package,files|
					if files.include?(path)
						file.package = package
						break
					end
				end
			end

			@files_to_install << file
		end

		# List of packages containing files for this version
		@packages = []
		package_file_map.each do |package_name,files|
			path = "#{output_dir}/#{package_name}.zip"
			package = UpdateScriptPackage.new
			package.name = package_name
			package.size = File.size(path)
			package.hash = file_sha1(path)
			@packages << package
		end
	end

	def toXML()
		doc = REXML::Document.new
		update_elem = REXML::Element.new("update")
		doc.add_element update_elem

		update_elem.add_element deps_to_xml()
		update_elem.add_element packages_to_xml()
		update_elem.add_element install_to_xml()

		output = ""
		doc.write output
		return output
	end

	def deps_to_xml()
		deps_elem = REXML::Element.new("dependencies")
		deps = ["updater.exe"]
		deps.each do |dependency|
			dep_elem = REXML::Element.new("file")
			dep_elem.text = dependency
			deps_elem.add_element dep_elem
		end
		return deps_elem
	end

	def packages_to_xml()
		packages_elem = REXML::Element.new("packages")
		@packages.each do |package|
			package_elem = REXML::Element.new("package")
			packages_elem.add_element package_elem
			hash_to_xml(package_elem,{
				"name" => package.name,
				"size" => package.size.to_s,
				"hash" => package.hash
			})
		end
		return packages_elem
	end

	def install_to_xml()
		install_elem = REXML::Element.new("install")
		@files_to_install.each do |file|
			file_elem = REXML::Element.new("file")
			install_elem.add_element(file_elem)

			attributes = {"name" => file.path}
			if (file.target)
				attributes["target"] = file.target
			else
				attributes["size"] = file.size.to_s
				attributes["permissions"] = file.permissions.to_s
				attributes["hash"] = file.hash
				attributes["package"] = file.package
			end
			hash_to_xml(file_elem,attributes)
		end
		return install_elem
	end

	def file_sha1(path)
		return `sha1sum "#{path}"`.split(' ')[0]
	end

	# Unix permission flags
	# from <sys/stat.h>
	S_IRUSR = 0400
	S_IWUSR = 0200
	S_IXUSR = 0100
	S_IRGRP = (S_IRUSR >> 3)
	S_IWGRP = (S_IWUSR >> 3)
	S_IXGRP = (S_IXUSR >> 3)
	S_IROTH = (S_IRGRP >> 3)
	S_IWOTH = (S_IWGRP >> 3)
	S_IXOTH = (S_IXGRP >> 3)

	# Qt permission flags
	# (taken from QFile::Permission)
	QT_READ_OWNER  = 0x4000
	QT_WRITE_OWNER = 0x2000
	QT_EXEC_OWNER  = 0x1000
	QT_READ_USER   = 0x0400
	QT_WRITE_USER  = 0x0200
	QT_EXEC_USER   = 0x0100
	QT_READ_GROUP  = 0x0040
	QT_WRITE_GROUP = 0x0020
	QT_EXEC_GROUP  = 0x0010
	QT_READ_OTHER  = 0x0004
	QT_WRITE_OTHER = 0x0002
	QT_EXEC_OTHER  = 0x0001

	def get_file_permissions(path)
		unix_to_qt = {
			S_IRUSR => QT_READ_USER  | QT_READ_OWNER,
			S_IWUSR => QT_WRITE_USER | QT_WRITE_OWNER,
			S_IXUSR => QT_EXEC_USER  | QT_EXEC_OWNER,
			S_IRGRP => QT_READ_GROUP,
			S_IWGRP => QT_WRITE_GROUP,
			S_IXGRP => QT_EXEC_GROUP,
			S_IROTH => QT_READ_OTHER,
			S_IWOTH => QT_WRITE_OTHER,
			S_IXOTH => QT_EXEC_OTHER
		}

		qt_permissions = 0
		unix_permissions = File.stat(path).mode
		unix_to_qt.each do |unix_flag,qt_flags|
			qt_permissions |= qt_flags if ((unix_permissions & unix_flag) != 0)
		end

		return qt_permissions.to_i
	end
end

class PackageMap
	def initialize(map_file)
		@rule_map = {}
		map_json = JSON.parse(File.read(map_file))
		map_json.each do |package,rules|
			rules.each do |rule|
				rule_regex = Regexp.new(rule)
				@rule_map[rule_regex] = package
			end
		end
	end

	def package_for_file(file)
		@rule_map.each do |rule,package|
			if (file =~ rule)
				return package
			end
		end
		return nil
	end
end

OptionParser.new do |parser|
	parser.banner = "#{$0} <input dir> <package map file> <output dir>"
end.parse!

if ARGV.length < 3
	raise "Missing arguments"
end

input_dir = ARGV[0]
package_map_file = ARGV[1]
output_dir = ARGV[2]

# get the details of each input file
input_file_list = []
Find.find(input_dir) do |path|
	next if (File.directory?(path))
	input_file_list << path
end

# map each input file to a corresponding package

# read the package map
package_map = PackageMap.new(package_map_file)

# map of package name -> array of files
package_file_map = {}
input_file_list.each do |file|
	next if File.symlink?(file)

	package = package_map.package_for_file(file)
	if (!package)
		raise "Unable to find package for file #{file}"
	end
	package_file_map[package] = [] if !package_file_map[package]
	package_file_map[package] << file
end

# generate each package
package_file_map.each do |package,files|
	puts "Generating package #{package}"

	quoted_files = []
	files.each do |file|
		quoted_files << "\"#{strip_prefix(file,input_dir)}\""
	end
	quoted_file_list = quoted_files.join(" ")

	output_path = File.expand_path(output_dir)
	Dir.chdir(input_dir) do
#if (!system("zip #{output_path}/#{package}.zip #{quoted_file_list}"))
#			raise "Failed to generate package #{package}"
#		end
	end
end

# output the file_list.xml file
update_script = UpdateScriptGenerator.new(input_dir,output_dir,input_file_list,package_file_map)
output_xml_file = "#{output_dir}/file_list.unformatted.xml"
File.open(output_xml_file,'w') do |file|
	file.write update_script.toXML()
end

# xmllint generates more readable formatted XML than REXML, so write unformatted
# XML first and then format it with xmllint.
system("xmllint --format #{output_xml_file} > #{output_dir}/file_list.xml")
File.delete(output_xml_file)

