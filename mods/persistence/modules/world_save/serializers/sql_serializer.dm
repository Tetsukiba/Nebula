/serializer/sql
	var/list_index = 1

	var/list/thing_inserts = list()
	var/list/var_inserts = list()
	var/list/element_inserts = list()
	var/list/ref_updates = list()

	var/tot_element_inserts = 0

	var/autocommit = TRUE // whether or not to autocommit after a certain number of inserts.
	var/inserts_since_commit = 0
	var/autocommit_threshold = 5000

	var/inserts_since_ref_update = 0 // we automatically commit refs to the database in batches on load
	var/ref_update_threshold = 200

	// Add the flatten serializer.
	var/serializer/json/flattener

	
	var/static/byondChar			// byondChar isn't unicode valid, so we have to get this at runtime
	var/static/utf8Char = "\uF811"	// this is a Private Use character in utf8 that we can use as a replacement

#ifdef SAVE_DEBUG
	var/verbose_logging = FALSE
#endif


/serializer/sql/New()
	..()
	flattener = new(src)
	
	if(isnull(byondChar))
		byondChar = copytext_char("\improper", 1, 2)

/serializer/sql/proc/byond2utf8(var/text)
	return replacetext(text, byondChar, utf8Char)

/serializer/sql/proc/utf82byond(var/text)
	return replacetext(text, utf8Char, byondChar)

// Serialize an object datum. Returns the appropriate serialized form of the object. What's outputted depends on the serializer.
/serializer/sql/SerializeDatum(var/datum/object, var/object_parent)
	// Check for existing references first. If we've already saved
	// there's no reason to save again.
	if(isnull(object) || !object.should_save)
		return

	if(isnull(global.saved_vars[object.type]))
		return // EXPERIMENTAL. Don't save things without a whitelist.

	var/existing = thing_map["\ref[object]"]
	if (existing)
#ifdef SAVE_DEBUG
		to_world_log("(SerializeThing-Resv) \ref[thing] to [existing]")
		CHECK_TICK
#endif
		return existing

	// Thing didn't exist. Create it.
	var/p_i = object.persistent_id ? object.persistent_id : PERSISTENT_ID
	object.persistent_id = p_i

	var/x = 0
	var/y = 0
	var/z = 0

	object.before_save() // Before save hook.
	if(ispath(object.type, /turf))
		var/turf/T = object
		x = T.x
		y = T.y
		if(nongreedy_serialize && !("[T.z]" in z_map))
			return null
		try
			z = z_map["[T.z]"]
		catch
			z = T.z

#ifdef SAVE_DEBUG
	to_world_log("(SerializeThing) ('[p_i]','[object.type]',[x],[y],[z],'[ref(object)]')")
#endif
	thing_inserts.Add("('[p_i]','[object.type]',[x],[y],[z],'[ref(object)]')")
	inserts_since_commit++
	thing_map["\ref[object]"] = p_i

	for(var/V in object.get_saved_vars())
		if(!issaved(object.vars[V]))
			continue
		var/VV = object.vars[V]
		var/VT = "VAR"
#ifdef SAVE_DEBUG
		to_world_log("(SerializeThingVar) [V]")
#endif
		if(VV == initial(object.vars[V]))
			continue

		if(islist(VV) && !isnull(VV))
			// Complex code for serializing lists...
			if(length(VV) == 0)
				// Another optimization. Don't need to serialize lists
				// that have 0 elements.
#ifdef SAVE_DEBUG
				to_world_log("(SerializeThingVar-Skip) Zero Length List")
#endif
				continue
			VT = "LIST"
			VV = SerializeList(VV, object)
			if(isnull(VV))
#ifdef SAVE_DEBUG
				to_world_log("(SerializeThingVar-Skip) Null List")
#endif
				continue
		else if (isnum(VV))
			VT = "NUM"
		else if (istext(VV))
			VT = "TEXT"
			VV = byond2utf8(VV)
		else if (ispath(VV) || IS_PROC(VV)) // After /datum check to avoid high-number obj refs
			VT = "PATH"
		else if (isfile(VV))
			VT = "FILE"
		else if (isnull(VV))
			VT = "NULL"
		else if(get_wrapper(VV))
			VT = "WRAP"
			var/wrapper_path = get_wrapper(VV)
			var/datum/wrapper/GD = new wrapper_path
			if(!GD)
				// Missing wrapper!
				continue
			GD.on_serialize(VV)
			if(!GD.key)
				// Wrapper is null.
				continue
			VV = flattener.SerializeDatum(GD)
		else if (istype(VV, /datum))
			var/datum/VD = VV
			if(!VD.should_save(object))
				continue
			// Reference only vars do not serialize their target objects, and act only as pointers.
			if(V in global.reference_only_vars)
				VT = "OBJ"
				VV = VD.persistent_id ? VD.persistent_id : PERSISTENT_ID
			// Serialize it complex-like, baby.
			else if(should_flatten(VV))
				VT = "FLAT_OBJ" // If we flatten an object, the var becomes json. This saves on indexes for simple objects.
				VV = flattener.SerializeDatum(VV)
			else
				VT = "OBJ"
				VV = SerializeDatum(VV)
		else
			// We don't know what this is. Skip it.
#ifdef SAVE_DEBUG
			to_world_log("(SerializeThingVar-Skip) Unknown Var")
#endif
			continue
		VV = sanitizeSQL("[VV]")
#ifdef SAVE_DEBUG
		to_world_log("(SerializeThingVar-Done) ('[p_i]','[V]','[VT]',\"[VV]\")")
#endif
		var_inserts.Add("('[p_i]','[V]','[VT]',\"[VV]\")")
		inserts_since_commit++
	object.after_save() // After save hook.
	if(inserts_since_commit > autocommit_threshold)
		Commit()
	return p_i


// Serialize a list. Returns the appropriate serialized form of the list. What's outputted depends on the serializer.
/serializer/sql/SerializeList(var/list/_list, var/list_parent)
	if(isnull(_list) || !islist(_list))
		return

	var/list/existing = list_map["\ref[_list]"]
	if(existing)
#ifdef SAVE_DEBUG
		to_world_log("(SerializeList-Resv) \ref[_list] to [existing]")
		CHECK_TICK
#endif
		return existing

	var/found_element = FALSE
	var/list_ref = "\ref[_list]"
	var/l_i = "[list_index]"
	list_index++
	inserts_since_commit++
	list_map[list_ref] = l_i
	for(var/key in _list)
		var/ET = "NULL"
		var/KT = "NULL"
		var/KV = key
		var/EV = null
		if(!isnum(key))
			try
				EV = _list[key]
			catch
				EV = null // NBD... No value.
		if (isnull(key))
			KT = "NULL"
		else if(isnum(key))
			KT = "NUM"
		else if (istext(key))
			KT = "TEXT"
			key = byond2utf8(key)
		else if (ispath(key) || IS_PROC(key))
			KT = "PATH"
		else if (isfile(key))
			KT = "FILE"
		else if (islist(key))
			KT = "LIST"
			KV = SerializeList(key)
		else if(get_wrapper(key))
			KT = "WRAP"
			var/wrapper_path = get_wrapper(key)
			var/datum/wrapper/GD = new wrapper_path
			if(!GD)
				// Missing wrapper!
				continue
			GD.on_serialize(key)
			if(!GD.key)
				// Wrapper is null.
				continue
			KV = flattener.SerializeDatum(GD)
		else if(istype(key, /datum))
			var/datum/key_d = key
			if(!key_d.should_save(list_parent))
				continue
			if(should_flatten(KV))
				KT = "FLAT_OBJ" // If we flatten an object, the var becomes json. This saves on indexes for simple objects.
				KV = flattener.SerializeDatum(KV)
			else
				KT = "OBJ"
				KV = SerializeDatum(KV)
		else
#ifdef SAVE_DEBUG
			to_world_log("(SerializeListElem-Skip) Unknown Key. Value: [key]")
#endif
			continue

		if(!isnull(key) && !isnull(EV))
			if(isnum(EV))
				ET = "NUM"
			else if (istext(EV))
				ET = "TEXT"
				EV = byond2utf8(EV)
			else if (isnull(EV))
				ET = "NULL"
			else if (ispath(EV) || IS_PROC(EV))
				ET = "PATH"
			else if (isfile(EV))
				ET = "FILE"
			else if (islist(EV))
				ET = "LIST"
				EV = SerializeList(EV)
			else if(get_wrapper(EV))
				ET = "WRAP"
				var/wrapper_path = get_wrapper(EV)
				var/datum/wrapper/GD = new wrapper_path
				if(!GD)
					// Missing wrapper!
					continue
				GD.on_serialize(EV)
				if(!GD.key)
					// Wrapper is null.
					continue
				EV = flattener.SerializeDatum(GD)
			else if (istype(EV, /datum))
				if(should_flatten(EV))
					ET = "FLAT_OBJ" // If we flatten an object, the var becomes json. This saves on indexes for simple objects.
					EV = flattener.SerializeDatum(EV)
				else
					ET = "OBJ"
					EV = SerializeDatum(EV)
			else
				// Don't know what this is. Skip it.
#ifdef SAVE_DEBUG
				to_world_log("(SerializeListElem-Skip) Unknown Value")
#endif
				continue
		KV = sanitizeSQL("[KV]")
		EV = sanitizeSQL("[EV]")
#ifdef SAVE_DEBUG
		if(verbose_logging)
			to_world_log("(SerializeListElem-Done) ([l_i],\"[KV]\",'[KT]',\"[EV]\",\"[ET]\")")
#endif	
		found_element = TRUE
		element_inserts.Add("([l_i],\"[KV]\",'[KT]',\"[EV]\",\"[ET]\")")
		inserts_since_commit++
	
	if(!found_element) // There wasn't anything that actually needed serializing in this list, so return null.
		list_index--
		list_map -= list_ref
		return null
	return l_i

/serializer/sql/DeserializeDatum(var/datum/persistence/load_cache/thing/thing)
#ifdef SAVE_DEBUG
	var/list/deserialized_vars = list()
#endif

	// Checking for existing items.
	var/datum/existing = reverse_map["[thing.p_id]"]
	if(existing)
		return existing
	// Handlers for specific types would go here.
	if (ispath(thing.thing_type, /turf))
		// turf turf turf
		var/turf/T = locate(thing.x, thing.y, thing.z)
		if (!T)
			to_world_log("Attempting to deserialize onto turf [thing.x],[thing.y],[thing.z] failed. Could not locate turf.")
			return
		T.ChangeTurf(thing.thing_type)
		existing = T
	else
		// default creation
		existing = new thing.thing_type()
	existing.persistent_id = thing.p_id // Upon deserialization we reapply the persistent_id in the thing table to save space.
	reverse_map["[thing.p_id]"] = existing
	// Fetch all the variables for the thing.
	for(var/datum/persistence/load_cache/thing_var/TV in thing.thing_vars)
		// Each row is a variable on this object.
#ifdef SAVE_DEBUG
		deserialized_vars.Add("[TV.key]:[TV.var_type]")
#endif
		try
			switch(TV.var_type)
				if("NUM")
					existing.vars[TV.key] = text2num(TV.value)
				if("TEXT")
					TV.value = utf82byond(TV.value)
					existing.vars[TV.key] = TV.value
				if("PATH")
					existing.vars[TV.key] = text2path(TV.value)
				if("NULL")
					existing.vars[TV.key] = null
				if("WRAP")
					var/datum/wrapper/GD = flattener.QueryAndDeserializeDatum(TV.value)
					existing.vars[TV.key] = GD.on_deserialize()
				if("LIST")
					existing.vars[TV.key] = QueryAndDeserializeList(TV.value)
				if("OBJ")
					existing.vars[TV.key] = QueryAndDeserializeDatum(TV.value, TV.key in global.reference_only_vars)
				if("FLAT_OBJ")
					existing.vars[TV.key] = flattener.QueryAndDeserializeDatum(TV.value)
				if("FILE")
					existing.vars[TV.key] = file(TV.value)
		catch(var/exception/e)
			to_world_log("Failed to deserialize '[TV.key]' of type '[TV.var_type]' on line [e.line] / file [e.file] for reason: '[e]'.")
#ifdef SAVE_DEBUG
	to_world_log("Deserialized thing of type [thing.thing_type] ([thing.x],[thing.y],[thing.z]) with vars: " + jointext(deserialized_vars, ", "))
#endif
	ref_updates["[existing.persistent_id]"] = ref(existing)
	inserts_since_ref_update++
	if(inserts_since_ref_update > ref_update_threshold)
		CommitRefUpdates()
	return existing

/serializer/sql/DeserializeList(var/raw_list)
	var/list/existing = list()
	// Will deserialize and return a list.
	// to_world_log("deserializing list with [length(raw_list)] elements.")
	for(var/datum/persistence/load_cache/list_element/LE in raw_list)
		var/key_value
		// to_world_log("deserializing list element [LE.key_type].")
		try
			switch(LE.key_type)
				if("NULL")
					key_value = null
				if("TEXT")
					LE.key = utf82byond(LE.key)
					key_value = LE.key
				if("NUM")
					key_value = text2num(LE.key)
				if("PATH")
					key_value = text2path(LE.key)
				if("WRAP")
					var/datum/wrapper/GD = flattener.QueryAndDeserializeDatum(LE.key)
					key_value = GD.on_deserialize()
				if("LIST")
					key_value = QueryAndDeserializeList(LE.key)
				if("OBJ")
					key_value = QueryAndDeserializeDatum(LE.key)
				if("FLAT_OBJ")
					key_value = flattener.QueryAndDeserializeDatum(LE.key)
				if("FILE")
					key_value = file(LE.key)

			switch(LE.value_type)
				if("NULL")
					// This is how lists are made. Everything else is a dict.
					existing += list(key_value)
				if("TEXT")
					LE.value = utf82byond(LE.value)
					existing[key_value] = LE.value
				if("NUM")
					existing[key_value] = text2num(LE.value)
				if("PATH")
					existing[key_value] = text2path(LE.value)
				if("WRAP")
					var/datum/wrapper/GD = flattener.QueryAndDeserializeDatum(LE.value)
					existing[key_value] = GD.on_deserialize()
				if("LIST")
					existing[key_value] = QueryAndDeserializeList(LE.value)
				if("OBJ")
					existing[key_value] = QueryAndDeserializeDatum(LE.value)
				if("FLAT_OBJ")
					existing[key_value] = flattener.QueryAndDeserializeDatum(LE.value)
				if("FILE")
					existing[key_value] = file(LE.value)

		catch(var/exception/e)
			to_world_log("Failed to deserialize list element [key_value] on line [e.line] / file [e.file] for reason: [e].")

	return existing

/serializer/sql/proc/Commit()
	establish_db_connection()
	if(!dbcon.IsConnected())
		return

	var/DBQuery/query
	try
		if(length(thing_inserts) > 0)
			query = dbcon.NewQuery("INSERT INTO `thing`(`p_id`,`type`,`x`,`y`,`z`,`ref`) VALUES[jointext(thing_inserts, ",")] ON DUPLICATE KEY UPDATE `p_id` = `p_id`")
			query.Execute()
			if(query.ErrorMsg())
				to_world_log("THING SERIALIZATION FAILED: [query.ErrorMsg()].")
		if(length(var_inserts) > 0)
			query = dbcon.NewQuery("INSERT INTO `thing_var`(`thing_id`,`key`,`type`,`value`) VALUES[jointext(var_inserts, ",")]")
			query.Execute()
			if(query.ErrorMsg())
				to_world_log("VAR SERIALIZATION FAILED: [query.ErrorMsg()].")
		if(length(element_inserts) > 0) 
			tot_element_inserts += length(element_inserts)
			query = dbcon.NewQuery("INSERT INTO `list_element`(`list_id`,`key`,`key_type`,`value`,`value_type`) VALUES[jointext(element_inserts, ",")]")
			query.Execute()
			if(query.ErrorMsg())
				to_world_log("ELEMENT SERIALIZATION FAILED: [query.ErrorMsg()].")
	catch (var/exception/e)
		to_world_log("World Serializer Failed")
		to_world_log(e)

	thing_inserts.Cut(1)
	var_inserts.Cut(1)
	element_inserts.Cut(1)
	inserts_since_commit = 0

/serializer/sql/proc/CommitRefUpdates()
	establish_db_connection()
	if(!dbcon.IsConnected())
		return
	if(length(ref_updates) == 0)
		inserts_since_ref_update = 0
		return
	var/list/where_list = list()
	var/list/case_list = list()
	var/DBQuery/query
	for(var/p_id in ref_updates)
		where_list.Add("'[p_id]'")
		var/new_ref = sanitizeSQL(ref_updates[p_id])
		case_list.Add("WHEN `p_id` = '[p_id]' THEN '[new_ref]'")

	query = dbcon.NewQuery("UPDATE `thing` SET `ref` = CASE [jointext(case_list, " ")] END WHERE `p_id` IN ([jointext(where_list, ", ")])")
	query.Execute()
	if(query.ErrorMsg())
		to_world_log("REFERENCE UPDATE FAILED: [query.ErrorMsg()].")
	
	ref_updates.Cut()
	inserts_since_ref_update = 0

/serializer/sql/Clear()
	. = ..()
	thing_inserts.Cut(1)
	var_inserts.Cut(1)
	element_inserts.Cut(1)
	list_index = 1

// Deletes all saves from the database.
/serializer/sql/proc/WipeSave()
	var/DBQuery/query = dbcon.NewQuery("TRUNCATE TABLE `thing`;")
	query.Execute()
	if(query.ErrorMsg())
		to_world_log("UNABLE TO WIPE PREVIOUS SAVE: [query.ErrorMsg()].")
	query = dbcon.NewQuery("TRUNCATE TABLE `thing_var`;")
	query.Execute()
	if(query.ErrorMsg())
		to_world_log("UNABLE TO WIPE PREVIOUS SAVE: [query.ErrorMsg()].")
	query = dbcon.NewQuery("TRUNCATE TABLE `list_element`;")
	query.Execute()
	if(query.ErrorMsg())
		to_world_log("UNABLE TO WIPE PREVIOUS SAVE: [query.ErrorMsg()].")
	query = dbcon.NewQuery("TRUNCATE TABLE `z_level`;")
	query.Execute()
	if(query.ErrorMsg())
		to_world_log("UNABLE TO WIPE PREVIOUS SAVE: [query.ErrorMsg()].")
	Clear()