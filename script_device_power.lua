-- scripts/lua/script_device_power.lua
-- Written by Creasol, https://creasol.it linux@creasol.it
-- Used to check power from energy meter (SDM120, SDM230, ...) and performs the following actions
--   1. Send notification when consumed power is above a threshold (to avoid power outage)
--   2. Enabe/Disable electric heaters or other appliances, to reduced power consumption from the electric grid
--   3. Emergency lights: turn ON some LED devices in case of power outage, and turn off when power is restored
--   4. Show on DomBusTH LEDs red and green the produced/consumed power: red LED flashes 1..N times if power consumption is greater than 1..N kW; 
--      green LED flashes 1..M times if photovoltaic produces up to 1..M kWatt
--

-- Check that at least one changed device has "Power" string in its name, else return immediately. Used to avoid parsing this long script if not needed
commandArray={}
local found=0
for devName,devValue in pairs(devicechanged) do
	if (devName:find('Power')) then
		found=1
		break
	end
end
if (found==0) then return commandArray end	-- no device containing "Power" in its name has changed

-- At least a device with "Power" in its name has changed: let's go!
dofile "/home/pi/domoticz/scripts/lua/globalvariables.lua"  -- some variables common to all scripts
dofile "/home/pi/domoticz/scripts/lua/globalfunctions.lua"  -- some functions common to all scripts
dofile "/home/pi/domoticz/scripts/lua/config_power.lua"		-- configuration file
timeNow = os.date("*t")

function PowerInit()
	if (Power==nil) then Power={} end
	if (Power['th1']==nil) then Power['th1']=0 end
	if (Power['th2']==nil) then Power['th2']=0 end
	if (Power['above']==nil) then Power['above']=0 end
	if (Power['usage']==nil) then Power['usage']=0 end
	if (Power['disc']==nil) then Power['disc']=0 end
	if (Power['min']==nil) then Power['min']=0 end	-- current time minute: used to check something only 1 time per minute
	if (Power['ev']==nil) then Power['ev']=0 end	-- used to force EV management now, without waiting 1 minute

	--if (PowerAux==nil) then PowerAux={} end
end	

function EVSEInit()
	if (EVSE==nil) then EVSE={} end
	if (EVSE['T']==nil) then EVSE['T']=0 end	-- EVSE: absolute time used to compute when power can stay over Threshold1 and below Threshold2 (27% over the contractual power)
	if (EVSE['t']==nil) then EVSE['t']=0 end	-- EVSE: time the EVSE is over Threshold2, to determine if charging must be stopped
	if (EVSE['S']==nil) then EVSE['S']='Dis' end	-- EVSE: last state
end

function evseSetGreenPower(Er, Et)	-- Er=green energy used to charge the vehicle in the last Et seconds
	local Eo=getEnergyValue(otherdevices_svalues[EVSE_RENEWABLE])	-- old renewable energy value
	local Pr=Er*3600/Et			-- current renewable power
	local Pc=getPowerValue(otherdevices[EVSE_POWERMETER])
	local Prperc=0
	if (Pc>0) then Prperc=math.floor(Pr*100/Pc) end
	-- if (Prperc>100) then Prperc=100 end
	table.insert(commandArray,	{['UpdateDevice'] = otherdevices_idx[EVSE_RENEWABLE].."|0|"..Pr..';'..tostring(Eo+Er)})	-- Update EVSE_greenPower
	table.insert(commandArray,{['UpdateDevice'] = otherdevices_idx[EVSE_RENEWABLE_PERCENTAGE].."|0|"..Prperc})			-- Update EVSE_green/total percentage
	log(E_INFO,"EVSE: greenPower="..Pr.." "..Prperc.."%")
end

function getPowerValue(devValue)
	-- extract the power value from string "POWER;ENERGY...."
	for str in devValue:gmatch("[^;]+") do
		return tonumber(str)
	end
end

function getEnergyValue(devValue)
	-- extract the power value from string "POWER;ENERGY...."
	local i=0
	for str in devValue:gmatch("[^;]+") do
		if (i==0) then
			i=1
		else
			return tonumber(str)
		end
	end
end

function setAvgPower() -- store in the user variable avgPower the building power usage
	if (uservariables['avgPower']==nil) then
		-- create a Domoticz variable, coded in json, within all variables used in this module
		avgPower=currentPower
		url=DOMOTICZ_URL..'/json.htm?type=command&param=adduservariable&vname=avgPower&vtype=0&vvalue='..tostring(currentPower)
		os.execute('curl "'..url..'"')
		-- initialize variable
	else
		avgPower=tonumber(uservariables['avgPower'])
	end
	avgPower=(math.floor((avgPower*11 + currentPower - Power['usage'] )/12)) -- average on 12*5s=60s
end


function getPower() -- extract the values coded in JSON format from domoticz zPower variable, into Power dictionary
	if (Power==nil) then
		-- check variable zPower
		json=require("dkjson")
		if (uservariables['zPower']==nil) then
			-- create a Domoticz variable, coded in json, within all variables used in this module
			PowerInit()	-- initialize Power dictionary
			url=DOMOTICZ_URL..'/json.htm?type=command&param=adduservariable&vname=zPower&vtype=2&vvalue='
			os.execute('curl "'..url..'"')
			-- initialize variable
		else
			Power=json.decode(uservariables['zPower'])
		end
		PowerInit()
	end	
	if (PowerAux==nil) then
		-- check variable zPower
		json=require("dkjson")
		if (uservariables['zPowerAux']==nil) then
			-- create a Domoticz variable, coded in json, within all variables used in this module
			log(E_INFO,"ERROR: creating variable zPowerAux")
			PowerAux={}	-- initialize PowerAux dictionary
			url=DOMOTICZ_URL..'/json.htm?type=command&param=adduservariable&vname=zPowerAux&vtype=2&vvalue='
			os.execute('curl "'..url..'"')
			-- initialize variable
		else
			PowerAux=json.decode(uservariables['zPowerAux'])
			if (otherdevices['Pranzo_Stufetta']=='On' and PowerAux['f1']==nil) then
				log(E_INFO,"ERROR, Pranzo_Stufetta On manually")
			end
		end
		PowerInit()
	else
		log(E_INFO,"PowerAux!=nil")
		log(E_INFO,"PowerAux="..json.encode(PowerAux))
	end

	if (uservariables['zHeatPump']~=nil) then
		HP=json.decode(uservariables['zHeatPump'])  -- get HP[] with info from HeatPump
	end
	if (HP==nil or HP['Level']==nil) then
		HP={}
		HP['Level']=1
	end

	if (EVSE==nil) then
		-- check variable zPower
		json=require("dkjson")
		if (uservariables['zEVSE']==nil) then
			-- create a Domoticz variable, coded in json, within all variables used in this module
			EVSEInit()	-- initialize Power dictionary
			url=DOMOTICZ_URL..'/json.htm?type=command&param=adduservariable&vname=zEVSE&vtype=2&vvalue='
			os.execute('curl "'..url..'"')
			-- initialize variable
		else
			EVSE=json.decode(uservariables['zEVSE'])
		end
		EVSEInit()
	end	

end

function powerMeterAlert(on)
	for k,pma in pairs(PowerMeterAlerts) do
		if (on~=0) then
			if (otherdevices[ pma[1] ]~=pma[3]) then
				log(E_INFO,"Activate sould alert "..pma[1])
				commandArray[ pma[1] ]=pma[3]
			end
		else
			-- OFF command
			if (otherdevices[ pma[1] ]~=pma[2]) then
				log(E_INFO,"Disable sould alert "..pma[1])
				commandArray[ pma[1] ]=pma[2]
			end
		end
	end
end

function scanDEVauxlist()
	devOn=''	-- used to find a ON-device that can be turned off if forced==1
	devPower=0
	-- extract the name of the last device in Heaters that is ON
	for k,loadRow in pairs(DEVauxfastlist) do
		if (otherdevices[loadRow[1]]=='On') then
			devAuto=0
			devKey='f'..k
			if (PowerAux[devKey]~=nil) then
				devAuto=1
				devOn=loadRow[1]
				devPower=loadRow[4]
				log(E_INFO,"devOn="..devOn.." devPower="..devPower.." devAuto="..devAuto)
				return
			else
				-- current device was enabled manually, not enabled from script_device_power.lua
				log(E_INFO,"Aux fastload "..loadRow[1].." enabled manually, power="..loadRow[4])
				if (devOn=='') then
					devOn=loadRow[1]
					devPower=loadRow[4]
				end
			end
		end
	end
	for k,loadRow in pairs(DEVauxlist) do
		if (otherdevices[loadRow[1]]=='On') then
			devAuto=0
			devKey='a'..k
			if (PowerAux[devKey]~=nil) then
				devAuto=1
				devOn=loadRow[1]
				devPower=loadRow[4]
				log(E_INFO,"devOn="..devOn.." devPower="..devPower.." devAuto="..devAuto)
				return
			else
				-- current device was enabled manually, not enabled from script_device_power.lua
				log(E_INFO,"Aux load "..loadRow[1].." enabled manually, power="..loadRow[4])
				if (devOn=='') then
					devOn=loadRow[1]
					devPower=loadRow[4]
				end
			end
		end
	end
end

function powerDisconnect(forced,msg) 
	-- disconnect the last device in Heater table, that is ON. Return 0 in case that no devices have been disconnected
	scanDEVauxlist()
	if (devOn=='') then
		if (forced~=0) then
			-- TODO: try to disable overloadDisconnect devices
			for k,loadRow in pairs(overloadDisconnect) do
				if (otherdevices[ loadRow[1] ]=='On') then
					log(E_WARNING, msg..': disconnect '..loadRow[1])
					commandArray[ loadRow[1] ]=loadRow[2]
					Power['disc']=os.time()
					return 1
				end
			end
		end
		return 0
	elseif (devAuto~=0 or forced~=0) then
		log(E_WARNING, msg..': disconnect '..devOn..' to save '..devPower..'W')
		commandArray[devOn]='Off'
		PowerAux[devKey]=nil
		Power['disc']=os.time()
		return 1
	end
end

log(E_DEBUG,"========================= "..DEBUG_PREFIX.." ===========================")
currentPower=10000000 -- dummy value (10MW)
EVChargingPower=0
HPmode=otherdevices[HPMode]	-- 'Off', 'Winter' or 'Summer'
if (HPmode==nil) then 
	HPmode='Off' 
	log(E_INFO,"You should create a selector switch named "..HPMode.." with 3 levels: Off, Winter, Summer")
end

for devName,devValue in pairs(devicechanged) do
	if (PowerMeter~='') then
		-- use PowerMeter device, measuring instant power (goes negative in case of exporting)
		if (devName==PowerMeter) then
			currentPower=getPowerValue(devValue)
		end
	else
		-- use PowerMeterImport and PowerMeterExport (if available)
		if ((PowerMeterImport~='' and devName==PowerMeterImport) or (PowerMeterExport~='' and devName==PowerMeterExport)) then
			currentPower=getPowerValue(otherdevices[PowerMeterImport])
			if (PowerMeterExport~='') then 
				currentPower=currentPower-getPowerValue(otherdevices[PowerMeterExport]) 				
			end
		end
	end
	if (EVPowerMeter ~= '') then
		-- get actual EV charging power
		if (devName==EVPowerMeter) then
			-- new value from the electric vehicle charging power meter
			EVChargingPower=getPowerValue(devValue)
			-- output current value to led status
			if (EVLedStatus ~= '') then
				l=(math.floor(EVChargingPower/1000))*10	-- 0=0..999W, 1=1000..1999, 2=2000..2999W, ...
				for k,led in pairs(EVLedStatus) do
					if (otherdevices_svalues[led]~=tostring(l)) then
						commandArray[led]="Set Level "..tostring(l)
						log(E_INFO,"EV: ChargingPower >= " .. l/10 .. "kW => Set leds")
					end
				end
			end
		end
	end
	-- EV: check EVChargingButton
	for k,evRow in pairs(eVehicles) do
		if (evRow[9]~='') then
			levelChanged=0
			if (devName==evRow[8]) then
				-- Charging button used to select between Off, Min0%, Min50%, Max100%, On modes
				-- find the current level
				levelItem=1
				levelName=EVChargingModeNames[1]
				levelMax=0
				for li,ln in pairs(EVChargingModeNames) do
					levelMax=levelMax+1
					if (otherdevices[ evRow[9] ]==ln) then 
						levelName=ln
						levelItem=li
					end
				end
				if (devValue=='Enable' and levelItem<levelMax) then
					levelItem=levelItem+1
					levelChanged=1
				elseif (devValue=='Disable' and levelItem>1) then
					levelItem=levelItem-1
					levelChanged=1
				end
				if (levelChanged==1) then
					-- evRow[4] is the battery min selector, and evRow[5] the battery max selector
					log(E_DEBUG,"EV: button pressed => set charging mode to "..EVChargingModeNames[ levelItem ] .. ", set battery min to "..EVChargingModeConf[ levelItem ][2].."% and battery max to "..EVChargingModeConf[ levelItem ][4].."%")
					commandArray[ evRow[9] ]='Set Level: '.. (levelItem-1)*10				-- set new charging mode
				end
			elseif (devName==evRow[9]) then
				-- changed selector switch
				log(E_DEBUG, "EV: Charging mode selector switch has been changed")
				levelItem=1
				levelName=EVChargingModeNames[1]
				for li,ln in pairs(EVChargingModeNames) do
					if (otherdevices[ evRow[9] ]==ln) then 
						levelName=ln
						levelItem=li
						break
					end
				end
				levelChanged=1
			end
			if (levelChanged==1) then
				-- update min and max battery level according to selector switch Charging Mode
				commandArray[ evRow[4] ]='Set Level: '..tostring(EVChargingModeConf[ levelItem ][1])	-- set min battery level
				commandArray[ evRow[5] ]='Set Level: '..tostring(EVChargingModeConf[ levelItem ][3])	-- set max battery level
				otherdevices[ evRow[4] ]=tostring(EVChargingModeConf[ levelItem ][2])
				otherdevices[ evRow[5] ]=tostring(EVChargingModeConf[ levelItem ][4])
				getPower() -- get Power variable from zPower domoticz variable (coded in JSON format)
				Power['ev']=1 -- force updating contactor output
				commandArray['Variable:zPower']=json.encode(Power)
			end
		end
	end
	-- if blackout, turn on white leds in the building!
	if (devName==blackoutDevice) then
		log(E_WARNING,"========== BLACKOUT: "..devName.." is "..devValue.." ==========")
		getPower()	-- get the Power dictionary from zPower variable
		if (devValue=='Off') then -- blackout
			for k,led in pairs(ledsWhite) do
				if (otherdevices[led]~=nil and otherdevices[led]~='0n') then
					commandArray[led]='On'
					Power['BL_'..k]='On'	-- store in a variable that this led was activated by blackout check
				end
			end
			for k,led in pairs(ledsWhiteSelector) do
				if (otherdevices_svalues[led]~=nil and otherdevices_svalues[led]~='1') then
					commandArray[led]="Set Level 1"
					Power['BLS_'..k]='On'	-- store in a variable that this led was activated by blackout check
				end
			end
		else -- power restored
			for k,led in pairs(ledsWhite) do
				if (otherdevices[led]~=nil and otherdevices[led]~='0ff' and (Power['BL_'..k]==nil or Power['BL_'..k]=='On')) then
					commandArray[led]='Off'
					Power['BL_'..k]=nil
				end
			end
			for k,led in pairs(ledsWhiteSelector) do
				if (otherdevices_svalues[led]~=nil and otherdevices_svalues[led]~='0' and (Power['BLS_'..k]==nil or Power['BLS_'..k]=='On')) then
					commandArray[led]="Set Level 0"
					Power['BLS_'..k]=nil
				end
			end
		end
	end
end


-- if currentPower~=10MW => currentPower was just updated => check power consumption, ....
if (currentPower>-20000 and currentPower<20000) then
	-- currentPower is good
	prodPower=0-currentPower
	getPower() -- get Power variable from zPower domoticz variable (coded in JSON format)
	setAvgPower()
	incMinute=0	-- zero if script was executed not at the start of the current minute
	if (Power['min']~=timeNow.min) then
		-- minute was incremented
		Power['min']=timeNow.min
		incMinute=1 -- minute incremented => set this variable to exec some checking and functions
	end


	-- update LED statuses (on Creasol DomBusTH modules, with red/green leds)
	-- red led when power usage >=0 (1=> <1000W, 2=> <2000W, ...)
	-- green led when power production >0 (1 if <1000W, 2 if <2000W, ...)
	--
	if (currentPower<0) then
		-- green leds
		l=math.floor(1-currentPower/1000)*10	-- 1=0..999W, 2=1000..1999W, ...
	else
		l=0	-- used power >0 => turn off green leds
	end
	for k,led in pairs(ledsGreen) do
		if (otherdevices_svalues[led]~=tostring(l)) then
			commandArray[led]="Set Level "..tostring(l)
		end
	end

	if (currentPower>0) then
		-- red leds
		l=(math.floor(currentPower/1000)+1)*10	-- 1=0..999W, 2=1000..1999, 3=2000..2999W, ...
	else
		l=0	-- used power >0 => turn off green leds
	end
	for k,led in pairs(ledsRed) do
		if (otherdevices_svalues[led]~=tostring(l)) then
			commandArray[led]="Set Level "..tostring(l)
		end
	end

	toleratedUsagePower=0
	if (timeNow.month<=3 or timeNow.month>=10) then -- winter
		toleratedUsagePower=300	-- from October to March, activate electric heaters even if the usage power will be >0W but <300W
	end

	if (currentPower<PowerThreshold[1]) then
		log(E_DEBUG,"currentPower="..currentPower.." < PowerThreshold[1]="..PowerThreshold[1])
		-- low power consumption => reset threshold timers, used to count from how many seconds power usage is above thresholds
		Power['th1']=0
		Power['th2']=0
		if (incMinute==1 or Power['ev']==1) then --Power['ev'] used to force EV management now
			Power['ev']=0
			for k,evRow in pairs(eVehicles) do
				-- evRow[1]=ON/OFF device
				-- evRow[2]=charging power
				-- evRow[3]=current battery level
				-- evRow[10]=current range (used to avoid problem with Kia battery level that often is not updated)
				-- evRow[4]=min battery level (charge to that level using imported energy!)
				-- evRow[5]=max battery level (stop when battery reached that level)
				if (otherdevices[ evRow[1] ]==nil or otherdevices[ evRow[4] ]==nil or otherdevices[ evRow[5] ]==nil) then
					log(E_WARNING,"EV: invalid device names in eVehicles structure, row number "..k)
				else
					if (Power['ev'..k]==nil) then
						Power['ev'..k]=0  --initialize counter, incremented every minute when there is not enough power from renewables to charge the vehicle
					end
					evPower=evRow[2]
					if (otherdevices[ evRow[4] ] == nil) then
						-- user must create the selector switch used to set the minimum level of battery
						log(E_WARNING,"EV: please create a virtual sensor, selector switch, named '"..evRow[4].."' with levels 0,10,20,..100")
						batteryMin=50
					else
						if (otherdevices[ evRow[4] ]=='Off') then
							batteryMin=0
						else
							batteryMin=tonumber(otherdevices[ evRow[4] ])
						end
					end
					if (otherdevices[ evRow[5] ] == nil) then
						-- user must create the selector switch used to set the maximum level of battery
						log(E_WARNING,"EV: please create a virtual sensor, selector switch, named '"..evRow[4].."' with levels 0,10,20,..100")
						batteryMax=80
					else
						if (otherdevices[ evRow[5] ]=='Off') then
							batteryMax=0
						else
							batteryMax=tonumber(otherdevices[ evRow[5] ])
						end
					end
					if (evRow[3]~='' and otherdevices[ evRow[3] ]~=nil) then
						-- battery state of charge is a device
						batteryLevel=tonumber(otherdevices[ evRow[3] ])	-- battery level device exists
						-- compare batteryLevel with battery range, because KIA UVO has a trouble with battery range not updating
						if (evRow[10]~='' and otherdevices[ evRow[10] ]~=nil) then
							batteryRange=tonumber(otherdevices[ evRow[10] ])
							if (batteryLevel<batteryRange/5.2) then
								log(E_WARNING,"EV: batteryLevel too low if compared with range")
								batteryLevel=batteryRange/5 	-- 400km = 80%
							end
						end
					elseif (uservariables[ evRow[3] ]~=nil) then
						-- battery state of charge is a variable
						batteryLevel=tonumber(uservariables[ evRow[3] ])
					else
						-- battery state of charge not available
						batteryLevel=batteryMin	-- battery level device does not exist => set to 50%
					end
					evDistance=0
					if (evRow[6]~='') then
						-- car distance sensor exists
						for name,value in pairs(otherdevices) do
							if (name:sub(1,evRow[6]:len()) == evRow[6]) then
								evDistance=tonumber(value)
							end
						end
					end
					evSpeed=0
					if (evRow[7]~='') then
						-- car speed sensor exists
						evSpeed=tonumber(otherdevices[ evRow[7] ])
					end
					log(E_DEBUG,"EV: Battery level="..batteryLevel.." Min="..batteryMin.." Max="..batteryMax)
					if (otherdevices[ evRow[1] ]=='Off') then
						-- not charging
						if (avgPower+evPower<PowerThreshold[1] and batteryLevel<batteryMax and ((evDistance<5 and evSpeed==0) or batteryMin==100)) then
							-- it's possible to charge without exceeding electricity meter threshold, and current battery level < battery max
							toleratedUsagePowerEV=evPower/3*(1-(batteryLevel-batteryMin)/(batteryMax-batteryMin))
							if (HPmode=='Winter') then toleratedUsagePowerEV=toleratedUsagePowerEV*2 end	-- in Winter, don't care if the car is partially charged by grid
							log(E_INFO,"EV: not charging, avgPower="..avgPower.." toleratedUsagePowerEV="..toleratedUsagePowerEV)
							if (batteryLevel<batteryMin or (avgPower+evPower)<toleratedUsagePowerEV) then
								-- if battery level > min level => charge only if power is available from renewable sources
								log(E_INFO,"EV: start charging - batteryLevel="..batteryLevel.."<"..batteryMin.." or ("..avgPower.."+"..evPower.."<"..toleratedUsagePowerEV)
								deviceOn(evRow[1],Power,'de'..k)
								Power['ev'..k]=0	-- counter
							end
						end
					else
						-- charging
						if ((evDistance>5 or evSpeed>0) and batteryMin<100) then
							log(E_INFO,"EV: car is moving or is not near home => stop charging")
							deviceOff(evRow[1],Power,'de'..k)
						elseif (batteryLevel>=batteryMin) then
							if (batteryLevel>=batteryMax) then
								-- reached the max battery level
								log(E_INFO,"EV: stop charging: reach the max battery level")
								deviceOff(evRow[1],Power,'de'..k)
							else
								-- still charging: check available power
								toleratedUsagePowerEV=evPower/2*(1-(batteryLevel-batteryMin)/(batteryMax-batteryMin))
								if (HPmode=='Winter') then toleratedUsagePowerEV=toleratedUsagePowerEV*2 end	-- in Winter, don't care if the car is partially charged by grid
								log(E_DEBUG,"EV: charging with batteryLevel>batteryMin, avgPower="..avgPower.." toleratedUsagePowerEV="..toleratedUsagePowerEV)
								if (avgPower>toleratedUsagePowerEV) then
									-- too much power consumption -> increment counter and stop when counter is high
									Power['ev'..k]=Power['ev'..k]+1	
									log(E_INFO,"EV: no enough energy from renewables since "..Power['ev'..k].." minutes")
									if (Power['ev'..k]>5) then
										log(E_INFO,"EV: stop charging")
										deviceOff(evRow[1],Power,'de'..k)
									end
								else
									log(E_DEBUG,"EV: enough energy to charge! ")
									Power['ev'..k]=0	-- enough energy from renewable => reset counter
								end
							end
						else
							-- batteryLevel < battery min level
							log(E_DEBUG,"EV: battery level lower than min value "..batteryMin)
						end
					end
				end
			end

			-- Every minute
			------------------------------------ check DEVauxlist to enable/disable aux devices (when we have/haven't got enough power from photovoltaic -----------------------------
			Power['usage']=0		-- compute power delivered to aux loads
			if (DEVauxlist~=nil) then
				log(E_DEBUG,"Parsing DEVauxlist...")
				if (HPmode=='Winter') then
					devCond=5 
					devLevel=2
				else 
					devCond=8 
					devLevel=3
				end
				for n,v in pairs(DEVauxlist) do
					if (otherdevices[ v[devCond] ]~=nil) then
						-- check timeout for this device (useful for dehumidifiers)
						s=""
						if (v[11]~=nil and PowerAux['s'..n]~=nil and PowerAux['s'..n]>0) then
							s=" ["..PowerAux['s'..n].."/"..v[11].."m]"
						end

						log(E_INFO,"Aux "..otherdevices[ v[1] ]..": "..v[1] .." (" .. v[4].."/"..prodPower.."W)"..s)
						if (tonumber(otherdevices[ v[devCond] ])<v[devCond+2]) then cond=1 else cond=0 end
						log(E_DEBUG,v[1] .. ": is " .. tonumber(otherdevices[ v[devCond] ]) .." < ".. v[devCond+2] .."? " .. cond)
						-- check timeout, if defined
						auxTimeout=0
						auxMaxTimeout=1440
						if (v[11]~=nil and v[11]>0) then
							-- max timeout defined => check that device has not reached the working time = max timeout in minutes
							auxMaxTimeout=v[11]
							checkVar('Timeout_'..v[1],0,0) -- check that uservariable at1 exists, else create it with type 0 (integer) and value 0
							auxTimeout=uservariables['Timeout_'..v[1]]
							if (otherdevices[ v[1] ]~='Off') then
								-- device is actually on => increment timeout
								auxTimeout=auxTimeout+1
								commandArray['Variable:Timeout_'..v[1]]=tostring(auxTimeout)
								if (auxTimeout>=v[11]) then
									-- timeout reached -> send notification and stop device
									deviceOff(v[1],PowerAux,'a'..n)
									log(TELEGRAM_LEVEL,"Timeout reached for "..v[1]..": device was stopped")
								end
							end
						end
						-- change state only if previous heatpump level match the current one (during transitions from a power level to another, power consumption changes)
						if (otherdevices[ v[1] ]~='Off') then
							-- device was ON
							log(E_DEBUG,'Device is not Off: '..v[1]..'='..otherdevices[ v[1] ])
							-- prodPower=prodPower-v[4]
							if (v[13]~='') then
								coff=load("return "..v[13])	-- expression that needs to turn off device
							else
								coff=load("return FALSE")
							end
							if (peakPower() or prodPower<-100 or (HP['Level']<v[devLevel] and HPmode~='Off') or cond==v[devCond+1] or coff()) then
								-- no power from photovoltaic, or heat pump is below the minimum level defined in config, or condition is not satisified, or OFF condition returns TRUE
								if (v[11]~=nil) then
									-- timeout for this device is set
									if (PowerAux['s'..n]==nil) then PowerAux['s'..n]=0 end
									PowerAux['s'..n]=PowerAux['s'..n]+1 -- increment the timeout counter
									if (PowerAux['s'..n]>=v[11]) then
										PowerAux['s'..n]=0
									end
								end
								-- stop device because conditions are not satisfied, or for more than v[11] minutes (timeout)
								deviceOff(v[1],PowerAux,'a'..n)
								prodPower=prodPower+v[4]    -- update prodPower, adding the power consumed by this device that now we're going to switch off
							else 
								-- device On, and can remain On
								Power['usage']=Power['usage']+v[4]
							end
						else
							-- device is OFF
							log(E_DEBUG,auxTimeout.."<"..auxMaxTimeout.." and "..prodPower..">="..v[4]+100 .." and "..cond.."~="..v[devCond+1].." and "..HP['Level']..">="..v[devLevel])
							if (v[12]~='') then
								con=load("return "..v[12])	-- expression that needs to turn off device
							else
								con=load("return 1")
							end
							if (peakPower()==false and auxTimeout<auxMaxTimeout and prodPower>=(v[4]+100) and cond~=v[devCond+1] and (HP['Level']>=v[devLevel] or HPmode=='Off') and con()) then
								deviceOn(v[1],PowerAux,'a'..n)
								prodPower=prodPower-v[4]  -- update prodPower
								Power['usage']=Power['usage']+v[4]
							end
						end
					end
				end
			end -- DEVauxlist exists
		end -- every 1 minute

		--	currentPower=-1200
		limit=toleratedUsagePower+100
		if (currentPower>limit) then
			-- disconnect only if power remains high for more than 5*2s
			if (Power['above']>=2) then 
				powerDisconnect(0,"currentPower>"..limit.." for more than 10 seconds") 
				Power['above']=0
			else
				Power['above']=Power['above']+1
				log(E_DEBUG, "currentPower > toleratedUsagePower+100 for "..(Power['above']*5).."s")
			end
		else
			-- usage power < than first threshold
			Power['above']=0
			if (HPmode=='Winter') then
				devCond=5 
				devLevel=2
			else 
				devCond=8 
				devLevel=3
			end
			-- exported power  => activate fast loads?
			for n,v in pairs(DEVauxfastlist) do
				if (otherdevices[ v[devCond] ]~=nil) then
					log(E_DEBUG,"Auxfast "..otherdevices[ v[1] ]..": "..v[1] .." (" .. v[4].."/"..prodPower.."W)")
					if (tonumber(otherdevices[ v[devCond] ])<v[devCond+2]) then cond=1 else cond=0 end
					log(E_DEBUG,v[1] .. ": is " .. tonumber(otherdevices[ v[devCond] ]) .." < ".. v[devCond+2] .."? " .. cond)
					-- change state only if previous heatpump level match the current one (during transitions from a power level to another, power consumption changes)
					if (otherdevices[ v[1] ]~='Off') then
						-- device was ON
						log(E_DEBUG,'Device is not Off: '..v[1]..'='..otherdevices[ v[1] ])
						if (v[13]~='') then
							coff=load("return "..v[13])	-- expression that needs to turn off device
						else
							coff=load("return FALSE")
						end
						if (peakPower() or prodPower<-200 or (HP['Level']<v[devLevel] and HPmode~='Off') or cond==v[devCond+1] or coff()) then
							-- no power from photovoltaic, or heat pump is below the minimum level defined in config, or condition is not satisified, or OFF condition returns TRUE
							-- stop device because conditions are not satisfied, or for more than v[11] minutes (timeout)
							deviceOff(v[1],PowerAux,'f'..n)
							prodPower=prodPower+v[4]    -- update prodPower, adding the power consumed by this device that now we're going to switch off
							Power['usage']=Power['usage']-v[4]
						-- else device On, and can remain On
						end
					else
						-- device is OFF
						log(E_DEBUG,prodPower..">="..v[4]+100 .." and "..cond.."~="..v[devCond+1].." and "..HP['Level']..">="..v[devLevel])
						if (v[12]~='') then
							con=load("return "..v[12])	-- expression that needs to turn off device
						else
							con=load("return 1")
						end
						log(E_DEBUG,prodPower..">=".. (v[4]) .." and "..cond.."~="..v[devCond+1] .." and (".. HP['Level'] ..">=".. v[devLevel] .." or "..HPmode.."=='Off') and "..con())
						if (peakPower()==false and prodPower>=(v[4]) and cond~=v[devCond+1] and (HP['Level']>=v[devLevel] or HPmode=='Off') and con()) then
							deviceOn(v[1],PowerAux,'f'..n)
							prodPower=prodPower-v[4]  -- update prodPower
							Power['usage']=Power['usage']+v[4]
						end
					end
				end
			end
			powerMeterAlert(0)
		end 
		powerMeterAlert(0)
	end

	----------------------------------  EVSE: check electric vehicle  --------------------------------------------------------------------
	if (EVSE_CURRENT_DEV~=nil and EVSE_CURRENT_DEV~='' and otherdevices[EVSE_CURRENT_DEV]~=nil) then
		-- EVSE device exists
		-- EVSE_CURRENT_DEV = device used to set the charging current
		-- EVSE_STATE_DEV = device with the current charging state
		-- EVSE['T']=time when charging has been started. Used to charge 80min at highest power (+27%) and 80m at high power (+10%) ^^^^^^^^^^__________^^^^^^^^_______
		if (EVSE_SOC_DEV~='' and otherdevices[EVSE_SOC_DEV]~=nil) then
			batteryLevel=tonumber(otherdevices[EVSE_SOC_DEV])
		else
			batteryLevel=0	-- don't know battery level => set to zero to charge anyway
		end
		if (batteryLevel>=tonumber(otherdevices_svalues[EVSE_SOC_MAX])) then
			-- battery charged => stop charging
			commandArray[EVSE_CURRENT_DEV]="Off"
		else
			if (otherdevices[EVSE_STATE_DEV]=='Con' and tonumber(otherdevices[EVSE_CURRENTMAX])>0 and batteryLevel<tonumber(otherdevices_svalues[EVSE_SOC_MAX]) and (PowerThreshold[1]-currentPower)>1800 and (currentPower<-800 or (batteryLevel<tonumber(otherdevices_svalues[EVSE_SOC_MIN]) and (timeNow.hour>=EVSE_NIGHT_START or timeNow.hour<EVSE_NIGHT_STOP or otherdevices[EVSE_SOC_MIN]=='On')))) then
				-- Connected, batteryLevel<EVSE_SOC_MAX, enough power from energy meter, and
				-- * extra power available from renewables, or
				-- * in the night, or
				-- * EVSE_SOC_MIN slide is active (On) => charge everytime
				--
				-- To charge only in the night, Disable the EVSE_SOC_MIN slider
				-- To enable charge now, just enable EVSE_SOC_MIN slider
				setCurrent=10   -- start charging
				EVSE['t']=0
				log(E_INFO,"EV: Start EV charging")
				commandArray[EVSE_CURRENT_DEV]="On"
				commandArray[EVSE_CURRENT_DEV]="Set Level "..tostring(setCurrent)
			elseif (otherdevices[EVSE_STATE_DEV]=='Ch') then
				-- Cable connected and device is charging
				-- charging!
				if (EVSE['S']~='Ch' and EVSE['S']~='Vent') then
					-- previous state: not charging
					-- start charging, and start measuring how much renewable energy is used
					EVSE['Et']=os.time()	-- start measuring energy
					EVSE['Ec']=getEnergyValue(otherdevices[EVSE_POWERMETER])
					EVSE['Ei']=getEnergyValue(otherdevices[EVSE_POWERIMPORT])
				end
				evtime=os.difftime(os.time(), EVSE['T'])
				if (evtime>PowerThreshold[3]*2) then
					EVSE['T']=os.time()
					evtime=0
				end
				currentNow=tonumber(otherdevices_svalues[EVSE_CURRENT_DEV])
				if (batteryLevel<tonumber(otherdevices_svalues[EVSE_SOC_MIN])) then
					-- use any power source, reneable and grid
					if (evtime<PowerThreshold[3]-60) then
						-- First 90 minutes => higest power (Power+27%)
						maxPower=PowerThreshold[2]
					else
						-- Remaining 90 minutes at high power (Power+10%) 
						maxPower=PowerThreshold[1]
					end
				else
					-- SOC_MIN <= SOC < SOC_MAX => use only renewable energy
					maxPower=0	-- currentPower should be negative (exported)
					if (currentNow>=6 and currentNow<=12 and batteryLevel<tonumber(otherdevices_svalues[EVSE_SOC_MAX])-5) then
						-- if charging current is really low and batteryLevel<BatteryMax-5, try to charge using some energy from grid, to improve charging efficiency
						maxPower=500
					end
				end
				-- Regulate the charging current
				availablePower=maxPower-currentPower
				setCurrent=0 -- default: do not change anything

				-- Charge at the maximum power
				availableCurrent=math.floor(availablePower/230)
				if (availableCurrent>=4 or availableCurrent<=-4) then
					availableCurrent=math.floor(availableCurrent/2)	-- increase or decrease slowly
				elseif (availableCurrent>=1) then
					availableCurrent=1  -- increase only 1 Ampere
				elseif (availableCurrent<=-1) then
					availableCurrent=-1
				else
					availableCurrent=0
				end
				-- if (availableCurrent~=0) then log(E_INFO,"EVSE: currentPower="..currentPower.." availablePower="..availablePower.." availableCurrent="..availableCurrent) end
				
				setCurrent=currentNow+availableCurrent
				if (setCurrent<6) then
					-- charge current should be reduced
					EVSE['t']=EVSE['t']+1
					maxtime=PowerThreshold[4]	-- max time after which the EVSE must be stopped to prevent disconnections
					if (currentPower<PowerThreshold[1]) then maxtime=180 end	-- probably setCurrent is low because only renewable energy should be use: increase maxtime
					log(E_INFO,"EV: Overload for ".. (EVSE['t']*5) .."/"..maxtime.."s")
					if (EVSE['t']*5>=maxtime) then
						log(E_INFO,"EV: disable charging because Power[EVt]>=maxtime")
						setCurrent=0
					else
						log(E_INFO,"EV: overload => set current=6A")
						setCurrent=6
					end
				else
					-- charge current ok
					if (EVSE['t']>=4) then EVSE['t']=EVSE['t']-4 end	-- decrease overload timeout
					if (setCurrent>tonumber(otherdevices[EVSE_CURRENTMAX])) then 
						setCurrent=tonumber(otherdevices[EVSE_CURRENTMAX])
					end
					if (setCurrent>EVSE_MAXCURRENTVALUE) then
						setCurrent=EVSE_MAXCURRENTVALUE
					end
				end
				if (setCurrent~=currentNow) then
					log(E_INFO,"EV: availablePower="..availablePower..", setCurrent="..setCurrent..", EVSE_current="..currentNow..", batteryLevel="..batteryLevel..", min="..otherdevices_svalues[EVSE_SOC_MIN]..", max="..otherdevices_svalues[EVSE_SOC_MAX])
					if (setCurrent>=6 and
						otherdevices[EVSE_CURRENT_DEV]=='Off') then
						commandArray[EVSE_CURRENT_DEV]="On"
					end
					commandArray[EVSE_CURRENT_DEV]="Set Level "..tostring(setCurrent)
				end
			end -- while charging
			EVSE['S']=otherdevices[EVSE_STATE_DEV]
		end
		Et=os.difftime(os.time(),EVSE['Et'])
		if (Et>=18) then
			-- while charging -> update EVSE_RENEWABLE energy meter
			Ec=getEnergyValue(otherdevices[EVSE_POWERMETER])
			Ei=getEnergyValue(otherdevices[EVSE_POWERIMPORT])
			Er=(Ec-EVSE['Ec'])-(Ei-EVSE['Ei'])	-- renewable energy used to charge the car
			if (Er<0) then Er=0 end
			evseSetGreenPower(Er,Et)	-- update the greenPower energy meter
			EVSE['Ec']=Ec
			EVSE['Ei']=Ei
			EVSE['Et']=os.time()
		end
	end

	if (currentPower>PowerThreshold[1]) then
		if (currentPower<PowerThreshold[2]) then
			-- power consumption a little bit more than available power => long intervention time, before disconnecting
			time=(os.time()-Power['th1'])
			log(E_WARNING, "Power>"..PowerThreshold[1].." for "..time.."s")
			Power['th2']=0
			if (Power['th1']==0) then
				Power['th1']=os.time()
			elseif (time>PowerThreshold[3]) then
				-- can I disconnect anything?
				time=os.time()-Power['disc']	-- disconnect devices every 50s
				if (powerDisconnect(1,"currentPower>"..PowerThreshold[1].." for more than "..PowerThreshold[3].."s")==0) then
					-- nothing to disconnect
					powerMeterAlert(1)	-- send alert
				else
					powerMeterAlert(0)
				end
			end
		else -- very high power consumption : short time to disconnect some loads
			time=(os.time()-Power['th2'])
			log(E_WARNING, "Power>"..PowerThreshold[2].." for "..time.."s")
			if (Power['th2']==0) then
				Power['th2']=os.time()
			elseif (time>PowerThreshold[4]) then
				-- can I disconnect anything?
				-- very high power consumption: short intervention time before power outage
				time=os.time()-Power['disc']	-- disconnect devices every 50s
				if (powerDisconnect(1,"currentPower>"..PowerThreshold[2].." for more than "..PowerThreshold[4].."s")==0) then
					-- nothing to disconnect
					powerMeterAlert(1)  -- send alert
					if ((time%20)==0) then log(E_CRITICAL,"Too much power consumption, and nothing to disconnect") end -- send alert by Telegram
				else
					powerMeterAlert(0)
				end

			end
		end
	end	-- currentPower has a right value
	-- save variables in Domoticz, in a json variable Power
	-- log(E_INFO,"commandArray['Variable:zPower']="..json.encode(Power))
	commandArray['Variable:zPower']=json.encode(Power)
	commandArray['Variable:zPowerAux']=json.encode(PowerAux)
	commandArray['Variable:zEVSE']=json.encode(EVSE)
	commandArray['Variable:avgPower']=tostring(avgPower)
	log(E_DEBUG,"currentPower="..currentPower.." avgPower="..avgPower.." Used_by_heaters="..Power['usage'])
	if (PowerAux~=nil) then
		log(E_DEBUG,"PowerAux="..json.encode(PowerAux))
	end
end
--print("power end: "..os.clock()-startTime) --DEBUG
if (commandArray~={}) then
	log(E_DEBUG,"commandArray not empty")
else
	log(E_DEBUG,"commandArray={}")
end

return commandArray
