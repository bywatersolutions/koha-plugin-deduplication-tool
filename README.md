# Introduction

This plugin is designed to make merging records and deduplicating catalogs faster and easier. The plugin uses existing matching rules

# Usage

When running the plugin the first page will be a search page, you can choose to limit the records checked for duplicates by entering criteria here. If none are entered the entire catalog will be search. *NOTE* I don't recommend this on catalogs of any significant size

The page will allow you to choose a matchign rule for comparing records, the plugin uses rules defined in the Koha Administration page

The results of the search (and merge report)  are displayed using the MergeReportFields system preference.

On the results page you will you can check the 'Merge' box to confirm merging of the records into the record selected in each row. Records will be preselected on basis of length or predetermined matching field value.

Once 'Merge selected records' is clicked you will recieve a results page showing successfully merged titles, or any errors.



# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-deduplication-tool/releases) you can download the relevant *.kpz file

# Installing

Koha's Plugin System allows for you to add additional tools and reports to Koha that are specific to your library. Plugins are installed by uploading KPZ ( Koha Plugin Zip ) packages. A KPZ file is just a zip file containing the perl files, template files, and any other files necessary to make the plugin work.

The plugin system needs to be turned on by a system administrator.

To set up the Koha plugin system you must first make some changes to your install.

* Change `<enable_plugins>0<enable_plugins>` to `<enable_plugins>1</enable_plugins>` in your koha-conf.xml file
* Confirm that the path to `<pluginsdir>` exists, is correct, and is writable by the web server
* Restart your webserver

Once set up is complete you will need to alter your UseKohaPlugins system preference. On the Tools page you will see the Tools Plugins and on the Reports page you will see the Reports Plugins.
