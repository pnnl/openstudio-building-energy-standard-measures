require "openstudio-standards"
require_relative "./resources/create_typical_resources.rb"

# start the measure
class CreateTypicalBuilding < OpenStudio::Measure::ModelMeasure

  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'Create Typical Building'
  end

  # human readable description
  def description
    return 'The "Create Typical Building" OpenStudio measures empowers users to effortlessly generate ' \
            'OpenStudio and EnergyPlus models by making a few select choices. Users can input preferences ' \
            'such as the building energy code year (e.g., ASHRAE 90.1-2013), climate zone, and desired heating, '\
            'ventilation, and air conditioning (HVAC) system.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This OpenStudio Measure analyzes and generates a standard building model using either the '\
           'current geometry or a pre-established geometry file. It considers the selected building energy '\
           'standard, the HVAC system, and the specific climate zone to create a standardized building model '\
           'within OpenStudio. Please note that choosing any option other than "Existing Geometry" will ' \
           'replace the current OSM file. Selecting "JSON-specified" under "HVAC Type" allows users to map '\
           'CBECS HVAC Systems to specific zones in the OSM model. An example file can be found at under this '\
           'measure\'s tests at .\tests\source\hvac_mapping_path\hvac_zone_mapping.json'
  end

  # define the arguments that the user will input
  def arguments(model)

    args = OpenStudio::Measure::OSArgumentVector.new

    #--------- Assign enumerations for inputs from constants
    geom_types = OpenStudio::StringVector.new
    geom_list = CreateTypicalBldgConstants::GEOMETRY_FILES
    geom_list.each do |geom_file|
      geom_types << geom_file
    end

    climate_zones = OpenStudio::StringVector.new
    cz_list = CreateTypicalBldgConstants::CLIMATE_ZONES
    cz_list.each do |climate_zone|
      climate_zones << climate_zone
    end

    templates = OpenStudio::StringVector.new
    code_list = CreateTypicalBldgConstants::STANDARD_ENERGY_CODES
    code_list.each do |building_code|
      templates << building_code
    end

    hvac_types = OpenStudio::StringVector.new
    hvac_list = CreateTypicalBldgConstants::HVAC_TYPES
    hvac_list.each do |hvac_type|
      hvac_types << hvac_type
    end

    #END--------- Assign enumerations for inputs

    # Add input elements
    geometry_file_choice = OpenStudio::Measure::OSArgument::makeChoiceArgument('geometry_file', geom_types, true)
    geometry_file_choice.setDisplayName("Geometry File")
    geometry_file_choice.setDefaultValue("Existing Geometry")
    args << geometry_file_choice

    climate_zone_choice = OpenStudio::Measure::OSArgument::makeChoiceArgument('climate_zone', climate_zones, true)
    climate_zone_choice.setDisplayName("Climate Zone")
    climate_zone_choice.setDefaultValue("Lookup From Model")
    args << climate_zone_choice

    template_choice = OpenStudio::Measure::OSArgument::makeChoiceArgument('template', templates, true)
    template_choice.setDisplayName("Building Energy Code")
    template_choice.setDefaultValue("90.1-2004")
    args << template_choice

    hvac_type_choice = OpenStudio::Measure::OSArgument::makeChoiceArgument('hvac_type', hvac_types, true)
    hvac_type_choice.setDisplayName("HVAC Type")
    hvac_type_choice.setDefaultValue("Inferred")
    args << hvac_type_choice

    # Path to HVAC-to-Zone mapping
    hvac_json_path = OpenStudio::Measure::OSArgument::makeStringArgument('user_hvac_json_path', false)
    hvac_json_path.setDisplayName('HVAC Zone Mapping JSON Path:')
    hvac_json_path.setDescription('Required if "JSON specified" is selected for "HVAC Type". Please'\
                                  ' enter a valid absolute path to a HVAC-to-Zone mapping JSON.')
    hvac_json_path.setDefaultValue('path/to/my/hvac_mapping.json')
    args << hvac_json_path

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)  # Do **NOT** remove this line

    runner.registerInfo("Starting create typical")

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # assign the user inputs to variables
    geometry_file = runner.getStringArgumentValue('geometry_file', user_arguments)
    climate_zone = runner.getStringArgumentValue('climate_zone', user_arguments)
    template = runner.getStringArgumentValue('template', user_arguments)
    hvac_type = runner.getStringArgumentValue('hvac_type', user_arguments)
    user_hvac_json_path = runner.getStringArgumentValue('user_hvac_json_path', user_arguments)

    # Load geometry file, if specified. NOTE, this will overwrite the existing OS model object
    if geometry_file != 'Existing Geometry'
      standard = Standard.new()
      #TODO This seems like a very sketchy way to call the private method load_geometry_osm
      new_model = standard.send(:load_geometry_osm,"geometry/#{geometry_file}")

      # Overwrite model with new geometry file
      model = overwrite_existing_model(model, new_model)
      runner.registerInfo("Model geometry overwritten with #{geometry_file}.")
    end

    runner.registerInfo("Model loaded, attempting Create Typical Building from model with parameters:")
    runner.registerInfo("Geometry Selection: #{geometry_file}")
    runner.registerInfo("Building Code: #{template}")
    runner.registerInfo("Climate Zone: #{climate_zone}")
    runner.registerInfo("HVAC System Type: #{hvac_type}")

    # If using an HVAC-to-Zone mapping defined in a user's JSON
    if hvac_type == 'JSON specified'

      # Process JSON file and check for errors
      hvac_mapping_hash = process_hvac_to_zone_mapping_json(model, user_hvac_json_path, runner)

      # An empty hvac mapping indicates an error, return false
      return false if hvac_mapping_hash.empty?
    end

    @create = OpenstudioStandards::CreateTypical
    runner.registerInfo("Begin typical model generation...")

    # If "Lookup From Model" is used, check that a climate zone was found in model. If not, return Error
    if climate_zone == 'Lookup From Model'
      climate_zone = standard.model_standards_climate_zone(model)
      if climate_zone == '' or climate_zone.nil?
        error_message = "Error when looking up climate zone from model. Ensure the model has a valid ClimateZone"\
        " or ClimateZones objects with climate zone information present. \n**NOTE**: Geometry files typically do not"\
        " have this information"
        runner.registerError(error_message)
        return false
      end

    end

    # Fire off CreateTypical method
    @create.create_typical_building_from_model(model, template, climate_zone: climate_zone,
                                               hvac_system_type: hvac_type, user_hvac_mapping: hvac_mapping_hash)

    # If no weather file assigned, assign it based on the climate zone
    if model.weatherFile.empty?

      # Assign design days and weather file to model
      runner.registerInfo("No weather file assigned to this model. Assigning default for climate zone: '#{climate_zone}'")
      standard = Standard.new()

      climate_zone = standard.model_get_building_properties(model)['climate_zone'] if climate_zone == 'Lookup From Model'
      standard.model_add_design_days_and_weather_file(model, climate_zone)

      # Get weather file name for reporting purposes
      location_name = model.weatherFile.get.site.get.name.to_s
      runner.registerInfo("Weather file and design days for #{climate_zone} assigned to '#{location_name}'")

    end

    # report final condition of model
    runner.registerFinalCondition("Typical building generation complete.")

    return true
  end

  def overwrite_existing_model(existing_model, new_model)

    # Overwrite model properly, per https://unmethours.com/question/32510/overwriting-a-osm-file-with-a-measure/
    handles = OpenStudio::UUIDVector.new
    existing_model.objects.each do |obj|
      handles << obj.handle
    end
    existing_model.removeObjects(handles)

    # Update references to new model
    existing_model.addObjects(new_model.toIdfFile.objects )

    return existing_model
  end

  # Checks a user's system to zone mapping for errors. Returns HVAC to zone mapping hash if defined correctly,
  # else returns empty hash
  def process_hvac_to_zone_mapping_json(model, user_hvac_json_path, runner)

    # if user data path not valid
    unless File.exists?(user_hvac_json_path)
      runner.registerError("The input user data path #{user_hvac_json_path} is not a valid file path! Please provide a valid file path.")
      return {}
    end

    runner.registerInfo("Reading in HVAC mapping information from #{user_hvac_json_path}.")

    # Read in user HVAC mapping JSON
    file = File.read(user_hvac_json_path)

    # Try to parse JSON
    begin
      hvac_mapping_hash = JSON.parse(file)
    rescue JSON::ParserError
      runner.registerError("Error in ''#{user_hvac_json_path}''. JSON parser failed to read file. Ensure "\
                           " #{user_hvac_json_path} is a valid JSON file")
      return {}
    end

    # Try to extract and aggregate thermal_zones from JSON
    begin
      zone_names_json = hvac_mapping_hash["systems"].flat_map { |system| system["thermal_zones"] }
    rescue NoMethodError
      runner.registerError("Error in ''#{user_hvac_json_path}''. Ensure JSON follows the format specified under"\
                           " 'systems'.[].'thermal_zones'")
      return {}
    end

    if zone_names_json.empty?
      runner.registerError("Error in the #{user_hvac_json_path}. No zones specified under 'systems'.[].'thermal_zones'")
      return {}
    end

    # Check for duplicate zones. First create a hash of every zones count
    count_occurrences = zone_names_json.each_with_object(Hash.new(0)) { |zone, counts| counts[zone] += 1 }

    # Select and return elements that have a count greater than 1 (i.e., duplicates)
    duplicates = count_occurrences.select { |zone, count| count > 1 }.keys

    unless duplicates.empty?
      runner.registerError("Error in the #{user_hvac_json_path}. Duplicate zones found: #{duplicates.join(', ')}")
      return {}
    end

    # Check the zones in the hash against those in the OS model
    zone_names_os_model = []
    model.getThermalZones.each do |zone|
      zone_names_os_model << zone.name.to_s
    end

    # Check for zones in JSON that don't exist in OS model using array subtraction
    nonexistant_zones = zone_names_json - zone_names_os_model

    unless nonexistant_zones.empty?
      runner.registerError("Error in the #{user_hvac_json_path}. The following zones don't exist in building "\
                           "'#{model.building.get.name.to_s}': #{nonexistant_zones.join(', ')}. NOTE, zone names are "\
                           "case sensitive.")
      return {}
    end

    runner.registerInfo("No issues found in: #{user_hvac_json_path}.")
    return hvac_mapping_hash

  end

  # module CreateTypicalBldgConstants
  #
  #   CLIMATE_ZONES = ['Lookup From Model',  'ASHRAE 169-2013-1A', 'ASHRAE 169-2013-2A', 'ASHRAE 169-2013-2B',
  #                    'ASHRAE 169-2013-3A', 'ASHRAE 169-2013-3B', 'ASHRAE 169-2013-3C', 'ASHRAE 169-2013-4A',
  #                    'ASHRAE 169-2013-4B', 'ASHRAE 169-2013-4C', 'ASHRAE 169-2013-5A', 'ASHRAE 169-2013-5B',
  #                    'ASHRAE 169-2013-6A', 'ASHRAE 169-2013-6B', 'ASHRAE 169-2013-7A', 'ASHRAE 169-2013-8A']
  #
  #   GEOMETRY_FILES = ['Existing Geometry',
  #                     'ASHRAESmallOffice.osm',
  #                     'ASHRAESmallHotel.osm',
  #                     'ASHRAESecondarySchool.osm',
  #                     'ASHRAERetailStripmall.osm',
  #                     'ASHRAEQuickServiceRestaurant.osm',
  #                     'ASHRAEPrimarySchool.osm',
  #                     'ASHRAEOutpatient.osm',
  #                     'ASHRAEMidriseApartment.osm',
  #                     'ASHRAEMediumOffice.osm',
  #                     'ASHRAELargeOffice.osm',
  #                     'ASHRAELargeHotel.osm',
  #                     'ASHRAELaboratory.osm',
  #                     'ASHRAEHospital.osm',
  #                     'ASHRAEHighriseApartment.osm',
  #                     'ASHRAEFullServiceRestaurant.osm',
  #                     'ASHRAECourthouse.osm',
  #                     'ASHRAECollege.osm',
  #
  #   ]
  #
  #   HVAC_TYPES = ['Inferred',
  #                 'JSON specified',
  #                 'Baseboard central air source heat pump',
  #                 'Baseboard district hot water',
  #                 'Baseboard electric',
  #                 'Baseboard gas boiler',
  #                 'Direct evap coolers with baseboard central air source heat pump',
  #                 'Direct evap coolers with baseboard district hot water',
  #                 'Direct evap coolers with baseboard electric',
  #                 'Direct evap coolers with baseboard gas boiler',
  #                 'Direct evap coolers with forced air furnace',
  #                 'Direct evap coolers with gas unit heaters',
  #                 'Direct evap coolers with no heat',
  #                 'DOAS with fan coil air-cooled chiller with baseboard electric',
  #                 'DOAS with fan coil air-cooled chiller with boiler',
  #                 'DOAS with fan coil air-cooled chiller with central air source heat pump',
  #                 'DOAS with fan coil air-cooled chiller with district hot water',
  #                 'DOAS with fan coil air-cooled chiller with gas unit heaters',
  #                 'DOAS with fan coil air-cooled chiller with no heat',
  #                 'DOAS with fan coil chiller with baseboard electric',
  #                 'DOAS with fan coil chiller with boiler',
  #                 'DOAS with fan coil chiller with central air source heat pump',
  #                 'DOAS with fan coil chiller with district hot water',
  #                 'DOAS with fan coil chiller with gas unit heaters',
  #                 'DOAS with fan coil chiller with no heat',
  #                 'DOAS with fan coil district chilled water with baseboard electric',
  #                 'DOAS with fan coil district chilled water with boiler',
  #                 'DOAS with fan coil district chilled water with central air source heat pump',
  #                 'DOAS with fan coil district chilled water with district hot water',
  #                 'DOAS with fan coil district chilled water with gas unit heaters',
  #                 'DOAS with fan coil district chilled water with no heat',
  #                 'DOAS with VRF',
  #                 'DOAS with water source heat pumps cooling tower with boiler',
  #                 'DOAS with water source heat pumps district chilled water with district hot water',
  #                 'DOAS with water source heat pumps fluid cooler with boiler',
  #                 'DOAS with water source heat pumps with ground source heat pump',
  #                 'Fan coil air-cooled chiller with boiler',
  #                 'Fan coil air-cooled chiller with baseboard electric',
  #                 'Fan coil air-cooled chiller with central air source heat pump',
  #                 'Fan coil air-cooled chiller with district hot water',
  #                 'Fan coil air-cooled chiller with gas unit heaters',
  #                 'Fan coil air-cooled chiller with no heat',
  #                 'Fan coil chiller with baseboard electric',
  #                 'Fan coil chiller with boiler',
  #                 'Fan coil chiller with central air source heat pump',
  #                 'Fan coil chiller with district hot water',
  #                 'Fan coil chiller with gas unit heaters',
  #                 'Fan coil chiller with no heat',
  #                 'Fan coil district chilled water with baseboard electric',
  #                 'Fan coil district chilled water with boiler',
  #                 'Fan coil district chilled water with central air source heat pump',
  #                 'Fan coil district chilled water with district hot water',
  #                 'Fan coil district chilled water with gas unit heaters',
  #                 'Fan coil district chilled water with no heat',
  #                 'Forced air furnace',
  #                 'Gas unit heaters',
  #                 'Packaged VAV Air Loop with Boiler', # second enumeration for backwards compatibility with Tenant Star project
  #                 'PSZ-AC district chilled water with baseboard district hot water',
  #                 'PSZ-AC district chilled water with baseboard electric',
  #                 'PSZ-AC district chilled water with baseboard gas boiler',
  #                 'PSZ-AC district chilled water with central air source heat pump',
  #                 'PSZ-AC district chilled water with district hot water',
  #                 'PSZ-AC district chilled water with electric coil',
  #                 'PSZ-AC district chilled water with gas boiler',
  #                 'PSZ-AC district chilled water with gas coil',
  #                 'PSZ-AC district chilled water with gas unit heaters',
  #                 'PSZ-AC district chilled water with no heat',
  #                 'PSZ-AC with baseboard district hot water',
  #                 'PSZ-AC with baseboard electric',
  #                 'PSZ-AC with baseboard gas boiler',
  #                 'PSZ-AC with central air source heat pump',
  #                 'PSZ-AC with district hot water',
  #                 'PSZ-AC with electric coil',
  #                 'PSZ-AC with gas boiler',
  #                 'PSZ-AC with gas coil',
  #                 'PSZ-AC with gas unit heaters',
  #                 'PSZ-AC with no heat',
  #                 'PSZ-HP',
  #                 'PTAC with baseboard district hot water',
  #                 'PTAC with baseboard electric',
  #                 'PTAC with baseboard gas boiler',
  #                 'PTAC with central air source heat pump',
  #                 'PTAC with district hot water',
  #                 'PTAC with electric coil',
  #                 'PTAC with gas boiler',
  #                 'PTAC with gas coil',
  #                 'PTAC with gas unit heaters',
  #                 'PTAC with no heat',
  #                 'PTHP',
  #                 'PVAV with central air source heat pump reheat',
  #                 'PVAV with district hot water reheat',
  #                 'PVAV with gas boiler reheat',
  #                 'PVAV with gas heat with electric reheat',
  #                 'PVAV with PFP boxes',
  #                 'Residential AC with baseboard central air source heat pump',
  #                 'Residential AC with baseboard district hot water',
  #                 'Residential AC with baseboard electric',
  #                 'Residential AC with baseboard gas boiler',
  #                 'Residential AC with no heat',
  #                 'Residential AC with residential forced air furnace',
  #                 'Residential forced air furnace',
  #                 'Residential heat pump',
  #                 'Residential heat pump with no cooling',
  #                 'VAV air-cooled chiller with central air source heat pump reheat',
  #                 'VAV air-cooled chiller with district hot water reheat',
  #                 'VAV air-cooled chiller with gas boiler reheat',
  #                 'VAV air-cooled chiller with gas coil reheat',
  #                 'VAV air-cooled chiller with no reheat with baseboard electric',
  #                 'VAV air-cooled chiller with no reheat with gas unit heaters',
  #                 'VAV air-cooled chiller with no reheat with zone heat pump',
  #                 'VAV air-cooled chiller with PFP boxes',
  #                 'VAV chiller with central air source heat pump reheat',
  #                 'VAV chiller with district hot water reheat',
  #                 'VAV chiller with gas boiler reheat',
  #                 'VAV chiller with gas coil reheat',
  #                 'VAV chiller with no reheat with baseboard electric',
  #                 'VAV chiller with no reheat with gas unit heaters',
  #                 'VAV chiller with no reheat with zone heat pump',
  #                 'VAV chiller with PFP boxes',
  #                 'VAV district chilled water with central air source heat pump reheat',
  #                 'VAV district chilled water with district hot water reheat',
  #                 'VAV district chilled water with gas boiler reheat',
  #                 'VAV district chilled water with gas coil reheat',
  #                 'VAV district chilled water with no reheat with baseboard electric',
  #                 'VAV district chilled water with no reheat with gas unit heaters',
  #                 'VAV district chilled water with no reheat with zone heat pump',
  #                 'VAV district chilled water with PFP boxes',
  #                 'VRF',
  #                 'Water source heat pumps cooling tower with boiler',
  #                 'Water source heat pumps district chilled water with district hot water',
  #                 'Water source heat pumps fluid cooler with boiler',
  #                 'Water source heat pumps with ground source heat pump',
  #                 'Window AC with baseboard central air source heat pump',
  #                 'Window AC with baseboard district hot water',
  #                 'Window AC with baseboard electric',
  #                 'Window AC with baseboard gas boiler',
  #                 'Window AC with forced air furnace',
  #                 'Window AC with no heat',
  #                 'Window AC with unit heaters']
  #
  #   STANDARD_ENERGY_CODES = ['DOE Ref 1980-2004', 'DOE Ref Pre-1980',
  #                            '90.1-2004', '90.1-2007', '90.1-2010',
  #                            '90.1-2013', '90.1-2016', '90.1-2019']
  #
  # end

end

# register the measure to be used by the application
CreateTypicalBuilding.new.registerWithApplication
