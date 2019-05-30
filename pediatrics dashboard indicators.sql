USE DSSI
GO

ALTER PROCEDURE [dbo].[sp_buildRichmondSSPDashboardIndicators]
AS
BEGIN

	/*
	Author: Hans Aisake
	Date Created: December 19, 2017
	Date Modified: April 23, 2018
	Purpose: Richmond Pediatrics Dashboard
	Compute metrics and establish lists and data sets for the Pediatrics Dashboard Report

	o   # of ED visits that touched the ED Short Stay Pediatrics Area
	o   # of visits that touched the Short Stay Pediatrics Area in Acute unit RSSP
	o   ALOS(hours) of RSSP Inpatients 
	o   ALOS(min) in ED Short Stay Pediatrics Area  
	o   # Repatriated Cases from Short Stay Pediatrics Acute Unit RSSP
	o   % of Discharges Sent to BC Children’s from ED and Acute SSP
	o	NOT REPORTED # Sent to Emerge Cases from Short Stay Pediatrics Acute Unit RSSP 
	o	NOT REPORTED # Sent to Surgery Cases from Short Stay Pediatrics Acute Unit RSSP 
	o   top 10 ED discharge diagnosis of ED SSP Patients
	o	top 10 discharge CMGs of RSSP Patients
	o   # of ED Visits by PWES age buckets
	o	# of Acute Admits by PWES age buckets

	By Fiscal Period or Fiscal Quarter depending on circumstances and data available as well as by Fiscal Year or YTD when incomplete.

	Stores the indicators, lists, and data sets into these tables.
	o   DSSI.dbo.RSSPDASH_MasterTableAll
	o	DSSI.dbo.RSSPDASH_MasterTableMostRecent
	o   DSSI.dbo.RSSPDASH_PEWSCounts_Acute
	o	DSSI.dbo.RSSPDASH_PEWSCounts_ED
	o   DSSI.dbo.RSSPDASH_Top10CMG_CurrentFY
	o	DSSI.dbo.RSSPDASH_Top10EDDx_CurrentFP



	Inclusions/exclusions:
	Original Specifications can be found here:
		Folder: \\vch.ca\departments\Projects (Dept VC)\Patient Flow Project\Richmond HSDA\2017 Requests\Pediatrics Dashboard\
		File: RE PEDS Dashboard

	COMMENTS------------------------
		COMMENT_-1*
		Perhaps should have just looked at ed patients and inpatients < X years of age instead of touching the ED SSP area stuff.

		COMMENT_0*
		Can't flag those sent to BC Children's hospital we don't record data to facilitate that identification.
		dischargedispositiondescription ='*BC Womens & Childrens Hospital' is only utilized by Lions Gate.
		Best I recall they are using a very different system than richmond, so we can't just do what they do.
		Nancy Autin has noted that discharged to other hospital for pediatrics patients are probably all going to BC Childrens.


		COMMENT_1* 
		I struggled with this choice, but in the end I thought of Census. If that persons is not physically in that bed don't count them.
		The admit times by and large are a bit before a patient ends up in a bed, however, transfers seam to be more reflective of that.
		Because of this I've prioritized the transfer time as the source of truth. I'm not sure I subscribe to the notion that a bed request locks a resource either.
		This is similar to confusion regarding ED inpatients, although SSP has an especially blurry boundry between ED and Acute care.

		COMMENT_2*
		I had to simplify the data to support links to discharges.
		Very rarely do I see more than one entry time for any account number, and it's usually noted as multiple transfers in from emerge.
		These cases only happened 9/774 times ~ 1.2% and I can live with this potential error.

		COMMENT_3*
		The proportion of clients going to X location is not tracked with good detail.

		COMMENT_4*
		Richmond doesn't directly track who is sent to BC Childrens, it has to be guessed using those sent to non-VCH acute care facilities.
		Interesting LGH does track this, likely because they are on a different acute care system than RHS.

		Fixed PEWS age group unknowns by fixing the age grouping logic. It was missing people durring the transitions between categories.
	*/

	--------------------------------------
	--Fiscal periods to report for, last 3 fiscal years + 1 fiscsal period
	--------------------------------------
		BEGIN IF OBJECT_ID('tempdb.dbo.#reportFP_SSPDash') IS NOT NULL DROP TABLE #reportFP_SSPDash END

		BEGIN
			SELECT distinct  TOP 40 fiscalperiodlong, fiscalperiodstartdate, fiscalperiodenddate
			INTO #reportFP_SSPDash
			FROM EDMart.dim.[Date]
			WHERE FiscalPeriodEnddate < GETDATE()	--fiscal period completed for at least 1 day, which is the ADTC data loading delay.
			AND FiscalPeriodEndDate>='2015-06-18'	--when data started comming in completely was 2016-04 with end date of 2015-06-19.
			ORDER BY FiscalPeriodEndDate DESC
		END

	--------------------------------------
	--Fiscal quarters to report for, last 16 completed fiscal quarters
	--------------------------------------
		BEGIN IF OBJECT_ID('tempdb.dbo.#fiscsalQuarters_SSPDash') IS NOT NULL DROP TABLE #fiscsalQuarters_SSPDash END

		BEGIN
			SELECT distinct TOP 16 FiscalQuarter
			, FiscalQuarterStartDate
			, FiscalQuarterEndDate
			INTO #fiscsalQuarters_SSPDash
			FROM ADTCMart.dim.[Date] 
			WHERE FiscalQuarterEndDate BETWEEN '2014-04-01' AND DATEADD(day, -1, GETDATE())	--fiscal quarter completed for at least 1 day. which is the ADTC data loading delay.
			AND FiscalQuarterEndDate>='2015-06-18'	--when data started comming in completely was 2016-04 with end date of 2015-06-19.
			ORDER BY FiscalQuarterEndDate DESC
		END

	--------------------------------------
	--Last 4 Fiscal years to report for
	--------------------------------------
		--Data started comming in completely was 2016-04 with end date of 2015-06-19. I've kept 2015/2016 values as they still say something.
		BEGIN IF OBJECT_ID('tempdb.dbo.#fiscalYears_SSPDash') IS NOT NULL DROP TABLE #fiscalYears_SSPDash END

		BEGIN
			SELECT TOP 4 FiscalYear
			, MIN(Shortdate) as 'FiscalYearStartDate'
			, MAX(Shortdate) as 'FiscalYearEndDate'
			INTO #fiscalYears_SSPDash
			FROM ADTCMart.dim.[Date] 
			WHERE Shortdate BETWEEN '2015-04-01' AND  DATEADD(day, -1, GETDATE()) --fiscal year compelted for at least 1 day, which is the ADTC data loading delay
			GROUP BY FiscalYear
			HAVING MAX(shortDate) > '2015-06-18'	--only fiscal years including and after data started comming in.
		END

	---------------------------------------
	--ID01 # ED Visits Touching SSP
	---------------------------------------
	/*
	Purpose: Find out how many unique ED visits touched the ED Short Stay Pediatrics Area.
	Author: Hans Aisake
	Date Created: March 6, 2018
	Date Modified:
	Inclusions/Exclusions:
	Comments:
	2016-03 doesn't have great data. I believe that is when we started collecting data for this area. It is included in the result.
	I validated that the records in the ED area data matched actual values shown on the ground in February 2018.
	*/

		--find all ED visit's that touched the SSP area listed as an ED area
		--If for some reason the ED area datetime is < start datetime flag the record.
		--If for some reason the ED area datetime is > disposition datetime flag the record.

		--table to hold the results
		BEGIN IF OBJECT_ID('tempdb.dbo.#ID01_RSSPDash') IS NOT NULL DROP TABLE #ID01_RSSPDash END

		-------------------------------
		--number of unique ed visits touching SSP in ED, by Fiscal Period
		-------------------------------
		BEGIN 
			SELECT 'Richmond' as 'Facility'
			, D.FiscalPeriodLong as 'TimeFrame'		--based on emergency area date
			, '# of ED visits touching SSP' as 'IndicatorName'
			, COUNT(distinct VisitID) as 'Metric'	--Num ED SSP Visits
			, NULL as 'Target'
			, 'Above' as 'DesiredDirection'
			, 'I' as 'Format'
			, 'P' as 'TimeFrameType'
			, 'EDMart-EDArea' as 'DataSource'
			INTO #ID01_RSSPDash
			FROM EDmart.dbo.vwEDVisitAreaRegional as EA
			INNER JOIN #reportFP_SSPDash as D
			ON EA.EmergencyAreaDate BETWEEN D.FiscalPeriodStartDate AND D.FiscalPeriodEndDate	--emergency area in a relevant fiscal period
			WHERE FacilityShortName='RHS'	--Richmond only
			and EmergencyAreaDescription ='Shortstay Peds - ED'	--touched the ED SSP area
			GROUP BY FacilityShortName
			, D.FiscalPeriodLong
			UNION
			--number of unique ed visits touching SSP in ED, by Fiscal Year
			SELECT 'Richmond' as 'Facility'
			, D.FiscalYear as 'TimeFrame'		--based on emergency area date
			, '# of ED visits touching SSP' as 'IndicatorName'
			, COUNT(distinct VisitID) as 'Metric'	--Num ED SSP Visits
			, NULL as 'Target'
			, 'Above' as 'DesiredDirection'
			, 'I' as 'Format'
			, 'Y' as 'TimeFrameType'
			, 'EDMart-EDArea' as 'DataSource'
			FROM EDmart.dbo.vwEDVisitAreaRegional as EA
			INNER JOIN #fiscalYears_SSPDash as D
			ON EA.EmergencyAreaDate BETWEEN D.FiscalYearStartDate AND D.FiscalYearEndDate	--emergency area in a relevant fiscal period
			WHERE FacilityShortName='RHS'	--Richmond only
			and EmergencyAreaDescription ='Shortstay Peds - ED'	--touched the ED SSP area
			GROUP BY FacilityShortName
			, D.FiscalYear
		END

	---------------------------------------
	--ID04 Average Time Noted Spent in ED SSP area
	---------------------------------------
	/*
	Purpose:
	Author: Hans Aisake
	Date Created: March 6, 2018
	Date Modified:
	Inclusions/Exclusions:
	Comments:
	2016-03 doesn't have great data. I believe that is when we started collecting data for this area. It is included in the result.
	*/

		--find the entry and exit times for ED area short stay pediatrics.
		--first note every who touched the area.
		BEGIN IF OBJECT_ID('tempdb.dbo.#sspVisits') IS NOT NULL DROP TABLE #sspVisits END

		--number of unique ed visits touching SSP in ED
		BEGIN
			SELECT distinct VisitID, EmergencyAreaDate + EmergencyAreaTime as 'EmergencyAreaDatetime'
			INTO #sspVisits
			FROM EDmart.dbo.vwEDVisitAreaRegional as EA
			INNER JOIN #reportFP_SSPDash as D
			ON EA.EmergencyAreaDate BETWEEN D.FiscalPeriodStartDate AND D.FiscalPeriodEndDate	--emergency area in a relevant fiscal period
			WHERE FacilityShortName='RHS'	--Richmond only
			and EmergencyAreaDescription ='Shortstay Peds - ED'	--touched the ED SSP area
		END

		--pull all ED area information for the visits that touched the Short Stay Pediatrics area noted above.
		BEGIN IF OBJECT_ID('tempdb.dbo.#sspVisitsAllEA') IS NOT NULL DROP TABLE #sspVisitsAllEA END

		BEGIN
			SELECT EA.VisitID
			, EA.EmergencyAreaDescription
			, EA.EmergencyAreaDatetime
			INTO #sspVisitsAllEA
			FROM (	SELECT VisitID, EmergencyAreaDescription, EmergencyAreaDate + EmergencyAreaTime as 'EmergencyAreaDatetime' 
					FROM EDmart.dbo.vwEDVisitAreaRegional
				 ) as EA
			INNER JOIN #sspVisits as SSP					--should find clones of each record and possibly more
			ON EA.VisitID =SSP.VisitID		--same ED visit
			AND  EA.EmergencyAreaDatetime >= SSP.EmergencyAreaDatetime	--emergency area date time >= the ED SSP entry time
		END

		--identify the order of the EA records for each client
		BEGIN IF OBJECT_ID('tempdb.dbo.#sspVisitsAllEA2') IS NOT NULL DROP TABLE #sspVisitsAllEA2 END

		BEGIN	
			SELECT ROW_NUMBER() OVER(partition by visitID ORDER by emergencyAreaDateTime ASC) as 'rn'
			, *
			INTO #sspVisitsAllEA2
			FROM #sspVisitsAllEA
		END

		--link records with their successor records in the EA data or the disposition from ED data to compute LOS in SSP.
		BEGIN IF OBJECT_ID('tempdb.dbo.#sspVisitsLOS') IS NOT NULL DROP TABLE #sspVisitsLOS END

		BEGIN
			SELECT X.VisitID
			, X.EmergencyAreaDescription as 'StartLocation'
			, ISNULL(Y.EmergencyAreaDescription,X.EmergencyAreaDescription) as 'EndLocation'
			, X.EmergencyAreaDatetime as 'EntryDatetime'
			, ISNULL(Y.EmergencyAreaDatetime, ED.DispositionDateTime) as 'ExitDateTime'
			, DATEDIFF(minute, X.EmergencyAreaDatetime, ISNULL(Y.EmergencyAreaDatetime, ED.DispositionDateTime)) as 'SSP_LOS (min)'
			INTO #sspVisitsLOS
			FROM #sspVisitsAllEA2 as X
			LEFT JOIN #sspVisitsAllEA2 as Y
			ON X.rn=Y.rn-1	--precessor linked to successor
			AND X.VisitID=Y.VisitID	--same ed visit record
			INNER JOIN (SELECT VisitID, StartDate, DispositionDate +DispositionTime as 'DispositionDateTime'
						FROM EDMart.dbo.vwEDVisitIdentifiedRegional
						WHERE FacilityShortName='RHS'
						) as ED
			ON X.VisitID=ED.VisitID
			WHERE X.EmergencyAreaDescription='Shortstay Peds - ED'
			AND DATEDIFF(minute, X.EmergencyAreaDatetime, ISNULL(Y.EmergencyAreaDatetime, ED.DispositionDateTime)) >0	--data quality filter that makes sure only records where the entry time < exit time is included
		END

		--find LOS by the reporting periods now and store the result
		BEGIN IF OBJECT_ID('tempdb.dbo.#ID04_RSSPDash') IS NOT NULL DROP TABLE #ID04_RSSPDash END
	
		BEGIN
			--By fiscal Period
			SELECT 'Richmond' as 'Facility'
			, D.FiscalPeriodLong as 'TimeFrame'
			, 'ED ALOS(min) in SSP' as 'IndicatorName' 
			, CAST(ROUND(1.0*SUM(LOS.[SSP_LOS (min)]) / COUNT(distinct visitID),0) as int) as 'Metric'
			, NULL as 'Target'
			, 'Below' as 'DesiredDirection'
			, 'I' as 'Format'
			, 'P' as 'TimeFrameType'
			, 'EDMart Emergency Area' as 'DataSource'
			INTO #ID04_RSSPDash
			FROM #sspVisitsLOS as LOS
			INNER JOIN #reportFP_SSPDash as D
			ON LOS.ExitDateTime BETWEEN D.FiscalPeriodStartDate AND D.FiscalPeriodEndDate
			GROUP BY D.FiscalPeriodLong
			--2016-03 doesn't have great data for this
			UNION
			--By fiscal year
			SELECT 'Richmond' as 'Facility'
			, D.FiscalYear as 'TimeFrame'
			, 'ED ALOS(min) in SSP' as 'IndicatorName' 
			, CAST(ROUND(1.0*SUM(LOS.[SSP_LOS (min)]) / COUNT(distinct visitID),0) as int) as 'Metric'
			, NULL as 'Target'
			, 'Below' as 'DesiredDirection'
			, 'I' as 'Format'
			, 'Y' as 'TimeFrameType'
			, 'EDMart Emergency Area' as 'DataSource'
			FROM #sspVisitsLOS as LOS
			INNER JOIN #fiscalYears_SSPDash as D
			ON LOS.ExitDateTime BETWEEN D.FiscalYearStartDate AND D.FiscalYearEndDate
			GROUP BY D.FiscalYear
			--2015/2016 doesn't have full data because 2015/2016-P3 is when data started, but 2015/2016-P4 is when data was good-ish onwards
		END

	---------------------------------------
	--ID02 # of visits that touched the Short Stay Pediatrics Area in Acute unit RSSP
	--ID03 find ALOS of the visits in ID02 when applicable
	---------------------------------------

	/*
	Purpose: Find those admited/discharge/transfered in or out of RSSP for ALOS and account counts.
	Author: Hans Aisake
	Date Created: March 5, 2018
	Date Modified:
	Inclusions/exclusions:
	--only includes those noted to end up in a RSSP bed
	--this implicitly only includes richmond clients
	--only includes those flagged as inpatient accounts
	--includes all age groups
	--only includes entries and exists from RSSP beds that were linkable
	--looks at single stays in RSSP, if a patient is noted as leaving and coming back they are treated as a new patient
	Comments:
	*/

		---------------------------------------------
		-- find entries into RSSP via a hybrid of transfers and admit data from ADTC.
		---------------------------------------------
			--------------------------------------------------------------------------------
			--Find admission records. RSSP filters make this Richmond only.
			--------------------------------------------------------------------------------
			--admits into RSSP are considered as those where the admitted bed is like RSSP%
			BEGIN IF OBJECT_ID('tempdb.dbo.#adtcRSSPAdmits') IS NOT NULL DROP TABLE #adtcRSSPAdmits END

			BEGIN
				SELECT PatientID, AccountNumber, AccountType, AdjustedAdmissionDate + CONVERT(datetime, AdjustedAdmissionTime,114) as 'AdjustedAdmissionDateTime'
				, AdmissionBed
				, AdmissionNursingUnitDesc
				, [site]
				INTO #adtcRSSPAdmits
				FROM ADTCMart.ADTC.vwAdmissionDischargeFact
				WHERE LEFT(AdmissionBed,4)='RSSP'			--I found this more accurate for capturing relvant admissions because a lot of them are listed as admitted into Emerge
				and AdjustedAdmissionDate >='2015-04-01'
				AND [Site]='RMD'	--Richmond only, redundant given RSSP filter above
			END

			---------------
			--transfers in
			---------------
			BEGIN IF OBJECT_ID('tempdb.dbo.#adtcRSSPTransIN') IS NOT NULL DROP TABLE #adtcRSSPTransIN END

			BEGIN
				SELECT PatientId, AccountNum, AccountType, AccountSubType
				, TransferDate + CONVERT(datetime, TransferTime,114) as 'TransferInDateTime'
				, ToNursingUnitCode,FromNursingUnitCode
				, ToBed, FromBed, [Site]
				INTO #adtcRSSPTransIN
				FROM ADTCMart.ADTC.vwTRansferFact
				WHERE LEFT(ToBed,4)='RSSP' and LEFT(FromBed,4)!='RSSP'	--transfers between RSSP beds
				AND transferdate >='2015-04-01'
				AND [Site]='RMD'	--Richmond only, redundant given RSSP filter above
			END

			-------------------------
			--consolidate entry data
			-------------------------
			BEGIN IF OBJECT_ID('tempdb.dbo.#consolidateIn') IS NOT NULL DROP TABLE #consolidateIn END

			BEGIN
				SELECT ISNULL(T.PatientID,A.PatientID) as 'PatientID'
				, ISNULL(T.AccountNum,A.AccountNumber) as 'AccountNumber'
				, ISNULL(T.TransferInDateTime,A.AdjustedAdmissionDateTime) as 'EntryDateTime'	--see COMMENT_1* in comments
				, CASE  WHEN ISNULL(T.AccountType,A.AccountType) in ('Inpatient','I') THEN 'I'
						ELSE 'Error'
				END as 'AccountType'
				, CASE WHEN T.FromNursingUnitCode !='REMR' THEN T.FromNursingUnitCode ELSE NULL END as 'FromOtherUnitDesc'
				, CASE  WHEN T.AccountNum IS NOT NULL AND A.AccountNumber IS NOT NULL  THEN 'TA'
						WHEN T.AccountNum IS NOT NULL AND A.AccountNumber IS NULL  THEN 'T'
						WHEN T.AccountNum IS NULL AND A.AccountNumber IS NOT NULL  THEN 'A'
						ELSE 'Error'
				END as 'RecordType'
				, ISNULL(T.ToBed, A.AdmissionBed) as 'EntryBed'
				INTO #consolidateIn
				FROM #adtcRSSPAdmits as A
				FULL OUTER JOIN #adtcRSSPTransIN as T
				ON A.AccountNumber=T.AccountNum
				WHERE A.AccountType='I' 
				OR T.AccountType='Inpatient'
			END

			--reduce to one entry per account number and ignore bouncing. See COMMENT_2* in comments.
			BEGIN
				DELETE Y
				FROM #consolidateIN Y
				LEFT JOIN (SELECT AccountNumber, MIN(EntryDateTime) as 'EntryDatetime' FROM #consolidateIn GROUP BY AccountNumber) X 
				ON Y.AccountNumber=X.AccountNumber AND Y.EntryDateTime=X.EntryDatetime
				WHERE X.AccountNumber is NULL
			END

		---------------------------------------------
		-- find entries into RSSP via a hybrid of transfers and admit data from ADTC.
		---------------------------------------------
			--------------------------------------------------------------------------------
			--Find discharge records. RSSP filters make this Richmond only.
			--------------------------------------------------------------------------------
			--admits into RSSP are considered as those where the admitted bed is like RSSP%
			BEGIN IF OBJECT_ID('tempdb.dbo.#adtcRSSPDischarges') IS NOT NULL DROP TABLE #adtcRSSPDischarges END

			BEGIN
				SELECT PatientID, AccountNumber, AccountType, AdjustedDischargeDate + CONVERT(datetime, AdjustedDischargeTime,114) as 'AdjustedDischargeDateTime'
				, DischargeBed
				, DischargeNursingUnitDesc
				, DischargeDispositionDescription
				INTO #adtcRSSPDischarges
				FROM ADTCMart.ADTC.vwAdmissionDischargeFact
				WHERE LEFT(DischargeBed,4)='RSSP'			--works just as well as discharge nursing unit
				AND AdjustedAdmissionDate >='2015-04-01'
				AND AccountType='I'
				AND [Site] ='rmd'
			END

			---------------
			--transfers out
			---------------
			BEGIN IF OBJECT_ID('tempdb.dbo.#adtcRSSPTransOut') IS NOT NULL DROP TABLE #adtcRSSPTransOut END

			BEGIN
				SELECT PatientId, AccountNum, AccountType, AccountSubType
				, TransferDate + CONVERT(datetime, TransferTime,114) as 'TransferOutDateTime'
				, ToNursingUnitCode
				, FromNursingUnitCode
				, ToBed
				, FromBed
				, ToFacilityLongName
				, HSDAName
				INTO #adtcRSSPTransOut
				FROM ADTCMart.ADTC.vwTRansferFact
				WHERE LEFT(FromBed,4)='RSSP' and LEFT(ToBed,4)!='RSSP'	--transfers between RSSP beds. works as well as unit
				AND transferdate >='2015-04-01'
				AND AccountType='Inpatient'
				--AND [Site] ='rmd' --removed because I want transfer from RHS to other hospitals to come through as exits.
			END

			-------------------------
			--consolidate exit data
			-------------------------
			--I don't see a reason to suspect there is any issue with either the discharge or the transfer out validity.
			--I am concerned though with linking it to the correct entry record, and I'm hoping the bedname can help with that.
			--because of this I think I can just union the data.
			BEGIN IF OBJECT_ID('tempdb.dbo.#consolidateOut') IS NOT NULL DROP TABLE #consolidateOut END

			BEGIN
				SELECT T.PatientID, T.AccountNum as 'AccountNumber', T.AccountType
				, T.ToNursingUnitCode as 'ToLocationDesc', T.TransferOutDateTime as 'ExitDateTime'
				, 'T' as 'RecordType', T.FromBed as 'ExitBed'
				INTO #consolidateOut
				FROM #adtcRSSPTransOut as T
				UNION
				SELECT D.PatientId, D.AccountNumber, D.AccountType
				, D.DischargeDispositionDescription as 'ToLocationDesc', D.AdjustedDischargeDateTime as 'ExitDateTime'
				, 'D' as 'RecordType', D.DischargeBed as 'ExitBed'
				FROM #adtcRSSPDischarges as D
			END
	
			--these links conflict with the census data a bit, but <1% error

		---------------------------------------------
		--find number of unique acute account numbers for ID02
		---------------------------------------------
			BEGIN IF OBJECT_ID('tempdb.dbo.#ID02_RSSPDash') IS NOT NULL DROP TABLE #ID02_RSSPDash END

			BEGIN
				--by fiscal period
				SELECT 'Richmond' as 'Facility'
				, FP.FiscalPeriodLong as 'TimeFrame'
				, '# of Inpatient Cases touching RSSP' as 'IndicatorName'
				, Count(distinct AccountNumber) as 'Metric'
				, NULL as 'Target'
				, 'Above' as 'DesiredDirection'
				, 'I' as 'Format'
				, 'P' as 'TimeFrameType'
				, 'ADTCMart a/d/t' as 'DataSource'
				INTO #ID02_RSSPDash
				FROM (
					SELECT AccountNumber, EntryDatetime as 'RecordDate' FROM #consolidateIn
					UNION
					SELECT AccountNumber, ExitDatetime as 'RecordDate' FROM #consolidateOut
				) as X
				INNER JOIN #reportFP_SSPDash as FP
				ON X.RecordDate BETWEEN FP.FiscalPeriodStartDate AND FP.FiscalPeriodEndDate
				GROUP BY FP.FiscalPeriodLong
				--by fiscal year
				UNION
				SELECT 'Richmond' as 'Facility'
				, D.FiscalYear as 'TimeFrame'
				, '# of Inpatient Cases touching RSSP' as 'IndicatorName'
				, Count(distinct AccountNumber) as 'Metric'
				, NULL as 'Target'
				, 'Above' as 'DesiredDirection'
				, 'I' as 'Format'
				, 'Y' as 'TimeFrameType'
				, 'ADTCMart a/d/t' as 'DataSource'
				FROM (
					SELECT AccountNumber, EntryDatetime as 'RecordDate' FROM #consolidateIn
					UNION
					SELECT AccountNumber, ExitDatetime as 'RecordDate' FROM #consolidateOut
				) as X
				INNER JOIN #fiscalYears_SSPDash as D
				ON X.RecordDate BETWEEN D.FiscalYearStartDate AND D.FiscalYearEndDate
				GROUP BY D.FiscalYear
			END

		---------------------------------------------
		--link ins and outs for ID03 ALOS
		---------------------------------------------
			--link the ins and outs together
			BEGIN IF OBJECT_ID('tempdb.dbo.#linkedInsOutsRSSP') IS NOT NULL DROP TABLE #linkedInsOutsRSSP END

			BEGIN
				SELECT I.AccountNumber
				, MIN(EntryDateTime) as 'EntryDateTime'
				, MAX(ExitDateTime) as 'ExitDateTime'
				, DATEDIFF(hour, MIN(EntryDateTime), MAX(ExitDateTime)) as 'RSSP_LOS(hours)'
				--, ToLocationDesc
				INTO #linkedInsOutsRSSP
				FROM #consolidateIn as I
				INNER JOIN #consolidateOut as O		--only keep records where in and out has been record for the same bed. ignore records that don't line up.
				ON I.AccountNumber=O.AccountNumber	--same account number. The facility has already implicitly been made to be the same with RSSP filters. It would take further thought about how to include site guarantees
				--AND I.EntryBed=O.ExitBed			--same bed in and out. Determined uppon manual inspection that this condition causes more harm than good. 12% data loss. Not sure why there isn't a perfect match between in and out beds.
				--when there are duplicates they appear to be exact
				AND EntryDateTime < ExitDateTime	--exit after entry
				GROUP BY I.AccountNumber
			END
			--682 inner join	--SELECT COUNT(*) FROM #consolidateIN
			--788 out			--SELECT COUNT(*) FROM #consolidateOut
			--774 in
			--over 100 records lost by joins, it is highly unlikely this is all because they are still here

			BEGIN IF OBJECT_ID('tempdb.dbo.#ID03_RSSPDash') IS NOT NULL DROP TABLE #ID03_RSSPDash END

		--compute metrics and store results
			BEGIN
				--Compute case counts and alos by FQ of RSSP LOS
				SELECT 'Richmond' as 'Facility'
				, D.FiscalQuarter as 'TimeFrame'
				, 'Inpatient ALOS(hours) of RSSP ' as 'IndicatorName'
				, CAST(ROUND(AVG(1.0*L.[RSSP_LOS(hours)]),2) as decimal(10,1)) as 'Metric' 
				--, COUNT(*) as 'NumCases'
				, NULL as 'Target'
				, 'Below' as 'DesiredDirection'
				, 'D1' as 'Format'
				, 'Q' as 'TimeFrameType'
				, 'ADTCMart' as 'DataSource'
				INTO #ID03_RSSPDash
				FROM #linkedInsOutsRSSP as L
				INNER JOIN #fiscsalQuarters_SSPDash as D		--most if not all NULLS are from the current incomplete fiscal quarter
				ON L.ExitDateTime BETWEEN D.FiscalQuarterStartDate AND D.FiscalQuarterEndDate
				GROUP BY D.FiscalQuarter
				UNION
				--Compute case counts and alos by FY of RSSP LOS
				SELECT 'Richmond' as 'Facility'
				, D.FiscalYear as 'TimeFrame'
				, 'Inpatient ALOS(hours) of RSSP ' as 'IndicatorName'
				, CAST(ROUND(AVG(1.0*L.[RSSP_LOS(hours)]),2) as decimal(10,1)) as 'Metric'
				--, COUNT(*) as 'NumCases'
				, NULL as 'Target'
				, 'Below' as 'DesiredDirection'
				, 'D1' as 'Format'
				, 'Y' as 'TimeFrameType'
				, 'ADTCMart' as 'DataSource'
				FROM #linkedInsOutsRSSP as L
				INNER JOIN #fiscalYears_SSPDash as D		--most if not all NULLS are from the current incomplete fiscal quarter
				ON L.ExitDateTime BETWEEN D.FiscalYearStartDate AND D.FiscalYearEndDate
				GROUP BY D.FiscalYear
			END

	---------------------------------------
	--ID05 Repatriated
	--ID06 Sent to BC Children's
	---------------------------------------
	/*
	Purpose: Find the number of patients Repatriated, Sent to BC Children's, Sent to Emergency Department, Sent to surgery
	Author: Hans Aisake
	Date Created: March 5, 2018
	Date Modified:
	Inclusions/exclusions:
	--only includes those noted to end up in a RSSP bed
	--this implicitly only includes richmond clients
	--only includes those flagged as inpatient accounts
	--includes all age groups
	--only includes entries and exists from RSSP beds that were linkable
	--looks at single stays in RSSP, if a patient is noted as leaving and coming back they are treated as a new patient
	Comments:
	*/
		----------------------
		--ID05 Repatriated
		----------------------
			--those who are transfered to another VCH facility who are not noted as being richmond clients who are in acute.
			BEGIN IF OBJECT_ID('tempdb.dbo.#ID05_RSSPDash') IS NOT NULL DROP TABLE #ID05_RSSPDash END

			BEGIN
				--by fiscal period
				SELECT 'Richmond' as 'Facility'
				, D.FiscalPeriodLong as 'TimeFrame'
				, '# Patients Repatriated from RSSP' as 'IndicatorName'
				, COUNT(distinct T.AccountNum) as 'Metric'
				, NULL as 'Target'
				, 'Above' as 'DesiredDirection'
				, 'I' as 'Format'
				, 'P' as 'TimeFrameType'
				, 'ADTCMart Transfers' as 'DataSource'
				INTO #ID05_RSSPDash
				FROM #adtcRSSPTransOut as T
				RIGHT JOIN #reportFP_SSPDash as D	--to ensure a result for all fiscal periods is returned for 0's in the counts.
				ON T.TransferOutDateTime BETWEEN D.FiscalPeriodStartDate AND D.FiscalPeriodEndDate
				AND T.ToFacilityLongName !='Richmond'
				AND T.HSDAName !='Richmond'					--patients transfered outside of richmond and who are not noted as richmond residents via their postal code
				GROUP BY D.FiscalPeriodLong
				UNION
				--by fiscal year
				SELECT 'Richmond' as 'Facility'
				, D.FiscalYear as 'TimeFrame'
				, '# Patients Repatriated from RSSP' as 'IndicatorName'
				, COUNT(*) as 'Metric'
				, NULL as 'Target'
				, 'Above' as 'DesiredDirection'
				, 'I' as 'Format'
				, 'Y' as 'TimeFrameType'
				, 'ADTCMart Transfers' as 'DataSource'
				FROM #adtcRSSPTransOut as T
				RIGHT JOIN #fiscalYears_SSPDash as D		--to ensure a result for all fiscalyears is returned for 0's in the counts. Doesn't matter though, we always have at least 1 case.
				ON T.TransferOutDateTime BETWEEN D.FiscalYearStartDate AND D.FiscalYearEndDate
				AND T.ToFacilityLongName !='Richmond'	--patients transfered outside of richmond
				AND HSDAName !='Richmond'				--who are not noted as richmond residents via their postal code
				GROUP BY D.FiscalYear
			END

		----------------------
		--ID06 Sent to BC Children's
		----------------------
			BEGIN IF OBJECT_ID('tempdb.dbo.#ID06_RSSPDash') IS NOT NULL DROP TABLE #ID06_RSSPDash END

			--pull all RSSP out records to identify cases that went to BC Childrens using the proxy definition
			--note that this includes all records not just those present in the LOS computations about 100 more cases.
			BEGIN
				SELECT 'Richmond' as 'Facility'
				, D.FiscalPeriodLong as 'TimeFrame'
				, '% of Discharges Sent to BC Children’s from ED and Acute SSP' as 'IndicatorName'
				, 1.0*COUNT(distinct CASE WHEN X.ToBCChildrensFlag=1 THEN X.AccountNumber ELSE NULL END)/IIF(COUNT(distinct X.AccountNumber)=0,NULL,COUNT(distinct X.AccountNumber))   as 'Metric'
				--, COUNT(distinct X.AccountNumber)   as 'NumRecords'
				, NULL as 'Target'
				, 'Below' as 'DesiredDirection'
				, 'P0' as 'Format'
				, 'P' as 'TimeFrameType'
				, 'ADTCMart & EDMart Emergency Area' as 'DataSource'
				INTO #ID06_RSSPDash
				FROM (
					SELECT REPLACE(LTRIM(REPLACE(AccountNumber, '0', ' ')), ' ', '0') as 'AccountNumber'
					, ExitDateTime
					, CASE WHEN ToLocationDesc in ('Discharged to Lower Mainland Hospital','Discharged to Other BC Hospital') THEN 1 ELSE 0 END as 'ToBCChildrensFlag'
					FROM #consolidateOut
					--join with records from ED using another BC Childrens proxy definition
					UNION
					SELECT VisitID as 'AccountNumber'
					, DispositionDate+ DispositionTime as 'ExitDateTime'
					, CASE WHEN Dischargedispositiondescription in ('Transfer to Outside Facility', 'Transferred to Another Hospital') THEN 1 ELSE 0 END as 'ToBCChildrensFlag'
					FROM EDMart.dbo.vwEDVisitIdentifiedRegional 
					WHERE VisitID in (SELECT visitID FROM #sspVisits)	--visit ID is for a SSP stay
					AND FacilityShortName='RHS'		--need to make sure it's richmond only data
				) as X
				RIGHT JOIN #reportFP_SSPDash as D	--to ensure 0's show up when there are no cases need RIGHT JOIN
				ON X.ExitDateTime BETWEEN D.FiscalPeriodStartDate AND D.FiscalPeriodEndDate
				GROUP BY D.FiscalPeriodLong
				UNION
				--by Fiscal Year
				SELECT 'Richmond' as 'Facility'
				, D.FiscalYear as 'TimeFrame'
				, '% of Discharges Sent to BC Children’s from ED and Acute SSP' as 'IndicatorName'
				, 1.0*COUNT(distinct CASE WHEN X.ToBCChildrensFlag=1 THEN X.AccountNumber ELSE NULL END)/IIF(COUNT(distinct X.AccountNumber)=0,NULL,COUNT(distinct X.AccountNumber))   as 'Metric'
				--, COUNT(distinct X.AccountNumber)   as 'NumRecords'
				, NULL as 'Target'
				, 'Below' as 'DesiredDirection'
				, 'P0' as 'Format'
				, 'Y' as 'TimeFrameType'
				, 'ADTCMart & EDMart Emergency Area' as 'DataSource'
				FROM (
					SELECT REPLACE(LTRIM(REPLACE(AccountNumber, '0', ' ')), ' ', '0') as 'AccountNumber'
					, ExitDateTime
					, CASE WHEN ToLocationDesc in ('Discharged to Lower Mainland Hospital','Discharged to Other BC Hospital') THEN 1 ELSE 0 END as 'ToBCChildrensFlag'
					FROM #consolidateOut
					--join with records from ED using another BC Childrens proxy definition
					UNION
					SELECT VisitID as 'AccountNumber'
					, DispositionDate+ DispositionTime as 'ExitDateTime'
					, CASE WHEN Dischargedispositiondescription in ('Transfer to Outside Facility') THEN 1 ELSE 0 END as 'ToBCChildrensFlag'
					FROM EDMart.dbo.vwEDVisitIdentifiedRegional 
					WHERE VisitID in (SELECT visitID FROM #sspVisits)	--visit ID is for a SSP stay
					AND FacilityShortName='RHS'		--need to make sure it's richmond only data
				) as X
				RIGHT JOIN #fiscalYears_SSPDash as D	--to ensure 0's show up when there are no cases you need RIGHT JOIN
				ON X.ExitDateTime BETWEEN D.FiscalYearStartDate AND D.FiscalYearEndDate
				GROUP BY D.FiscalYear
			END

		----------------------
		--ID07 to Emerge
		----------------------
		--this is not worth tracking based on the data I saw

		----------------------
		--ID08 to Surgery
		----------------------
		--this is not worth tracking based on the data I saw. Instead perhaps the pediatrics reports stella generates that note surgical cases would be more useful.

	----------------------
	--ID09 top 10 ED discharge diagnosis of ED SSP Patients
	----------------------
	/*
	Purpose: Find the top 10 discharge diagnosises of ED SSP Patients
	Author: Hans Aisake
	Date Created: March 5, 2018
	Date Modified:
	Inclusions/exclusions:
	--only includes those who touch the ED SSP area at some point durring their visit
	--only includes richmond clients extending to other regions would be impossible or highly difficult
	Comments:
	*/
		/*
		create a table to house the data for easier pulling in the report.
		CREATE TABLE DSSI.dbo.RSSPDASH_Top10EDDx_CurrentFP (
			FiscalPeriodLong char(7),
			DischargeDiagnosisDescription varchar(255),
			NumVisits int
		)
		*/

		BEGIN TRUNCATE TABLE DSSI.dbo.RSSPDASH_Top10EDDx_CurrentFP END

		BEGIN
			--add most current data, completed fiscal periods only.
			INSERT INTO DSSI.dbo.RSSPDASH_Top10EDDx_CurrentFP (FiscalPeriodLong, DischargeDiagnosisDescription, NumVisits)
			SELECT TOP 10 StartDateFiscalPeriodLong as 'FiscalPeriodLong'
			, DischargeDiagnosisDescription
			, COUNT(distinct VisitID) as 'NumVisits'
			FROM EDMart.dbo.vwEDVisitIdentifiedRegional as ED
			WHERE VisitID in (SELECT visitID FROM #sspVisits)
			AND FacilityShortName ='RHS'
			AND StartDateFiscalPeriodLong = (SELECT MAX(fiscalperiodlong) as 'fiscalperiodlong' from #reportFP_SSPDash)
			GROUP BY StartDatefiscalPeriodLong, DischargeDiagnosisDescription
			ORDER BY COUNT(distinct visitID) DESC
		END

	----------------------
	--ID10 top 10 discharge CMGs of RSSP Patients
	----------------------
	/*
	Purpose: Find the top 10 CMGs of Acute RSSP
	Author: Hans Aisake
	Date Created: March 5, 2018
	Date Modified: March 5, 2019
	Inclusions/exclusions:
	--only includes those who are discharged or transfered out of RSSP
	--only includes richmond clients extending to other regions would be impossible or highly difficult
	Comments:
	-- March 5, 2019 - Changed it to pull all CMGs for the latest years worth of data and call it the fiscal year

	--I think it's better to refer the clients to Stella's annual report instead of developing a new mechanism here
	--I'm not sure this is really that valuable as it is.
	*/

		--Identify the accounts that touched RSSP
		BEGIN IF OBJECT_ID('tempdb.dbo.#RRSP_AccountNums_RSSPDash') IS NOT NULL DROP TABLE #RRSP_AccountNums_RSSPDash END

		BEGIN
			SELECT REPLACE(LTRIM(REPLACE(AccountNumber, '0', ' ')), ' ', '0') as 'AccountNumber'
			INTO #RRSP_AccountNums_RSSPDash 
			FROM #consolidateIn
			UNION
			SELECT REPLACE(LTRIM(REPLACE(AccountNumber, '0', ' ')), ' ', '0') as 'AccountNumber' 
			FROM #consolidateOut
		END


		/*
		create a table to house the data for easier pulling in the report.
		CREATE TABLE DSSI.dbo.RSSPDASH_Top10CMG_CurrentFY (
			FiscalYear char(5),
			CMG varchar(255),
			NumCases int
		)
		*/

		--clear out the old top 10 CMG's noted in the table so we can repopulate with new values or updated values
		BEGIN TRUNCATE TABLE DSSI.dbo.RSSPDASH_Top10CMG_CurrentFY END

		BEGIN
			--find the top 10 CMG's of accounts that touched RSSP in the most recent rolling fiscal year.
			INSERT INTO DSSI.dbo.RSSPDASH_Top10CMG_CurrentFY (FiscalYear, CMG, NumCases)
			SELECT TOP 10 MAX(FiscalYear) as 'FiscalYear'
			, ISNULL(ADR.CMGPlusDesc,'No CMG Specified') as 'CMG'
			, COUNT(*) as 'NumCases'
			FROM ADRMart.dbo.vwAbstractFact as ADR
			WHERE FacilityShortName='RHS'			--Richmond only. Not extendable.
			AND RegisterNumber in (SELECT AccountNumber FROM #RRSP_AccountNums_RSSPDash)	--account has touched RSSP
			AND [DischargeDate] BETWEEN  (SELECT MAX([DischargeDate]) FROM ADRMArt.dbo.vwAbstractFact WHERE Facilityshortname='RHS')-10000	AND  (SELECT MAX([DischargeDate]) FROM ADRMArt.dbo.vwAbstractFact  WHERE Facilityshortname='RHS')  --admit date within the latest year of data
			GROUP BY ADR.CMGPlusDesc
			ORDER BY COUNT(*) DESC
		END

	----------------------
	--ID11 # of ED Visits by PWES age buckets
	----------------------
	--PWES buckets
	--o   0-3 months
	--o   4-11 months
	--o   1-3 years 
	--o   4-6 years 
	--o   7-11 years 
	--o   12+ years

		/*
		create a table to house the data for easier pulling in the report.
		CREATE TABLE DSSI.dbo.RSSPDASH_PEWSCounts_ED (
			FiscalPeriodLong varchar(255),
			PEWS_AgeGroup varchar(11),
			NumVisits int
		)
		*/

		--compute # of cases by PEWS age group and store the results
		BEGIN IF OBJECT_ID('tempdb.dbo.#RSSP_PEWS_ED_Counts') IS NOT NULL DROP TABLE #RSSP_PEWS_ED_Counts END

		BEGIN
			SELECT D.FiscalPeriodLong,
			CASE	WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 0 AND 3 THEN '0-3 Months'
					WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 4 AND 11 THEN '4-11 Months'
					WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 12*1 AND 12*3 THEN '1-3 Years'
					WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 12*3 AND 12*6 THEN '4-6 Years'
					WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 12*6 AND 12*11 THEN '7-11 Years'
					WHEN DATEDIFF(month, [BirthDate], Startdate) >= 12*11 THEN '12+ Years'
					WHEN DATEDIFF(month, [BirthDate], Startdate) <0 THEN 'Start<BirthDate'
					ELSE 'Unknown'
			END as 'PEWS_AgeGroup'
			, COUNT(distinct VisitID) as 'NumVisits'
			INTO #RSSP_PEWS_ED_Counts
			FROM EDMart.dbo.vwEDVisitIdentifiedRegional as ED
			INNER JOIN #reportFP_SSPDash as D
			ON ED.Dispositiondate BETWEEN D.FiscalPeriodStartDate AND D.FiscalPeriodEndDate		--ED disposition between fiscal period start and end
			WHERE VisitID in (SELECT visitID FROM #sspVisits)
			AND FacilityShortName ='RHS'
			GROUP BY D.FiscalPeriodLong,
			CASE	WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 0 AND 3 THEN '0-3 Months'
					WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 4 AND 11 THEN '4-11 Months'
					WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 12*1 AND 12*3 THEN '1-3 Years'
					WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 12*3 AND 12*6 THEN '4-6 Years'
					WHEN DATEDIFF(month, [BirthDate], Startdate) BETWEEN 12*6 AND 12*11 THEN '7-11 Years'
					WHEN DATEDIFF(month, [BirthDate], Startdate) >= 12*11 THEN '12+ Years'
					WHEN DATEDIFF(month, [BirthDate], Startdate) <0 THEN 'Start<BirthDate'
					ELSE 'Unknown'
			END	--PEWS AgeGroup
		END
	
		--clear historical table values
		BEGIN TRUNCATE TABLE DSSI.dbo.RSSPDASH_PEWSCounts_ED END

		--needed to add 0's because not every period is guaranteed to have someone in each age group.
		--I create a row for each expected combination based on data observered. Should be 0 if there is a non-0 for any group.
		--Almost never happens.
		BEGIN 
			INSERT INTO DSSI.dbo.RSSPDASH_PEWSCounts_ED  (FiscalPeriodLong, PEWS_AgeGroup, NumVisits)
			SELECT Y.FiscalPeriodLong
			, X.PEWS_AgeGroup
			, ISNULL(Z.NumVisits,0) as 'NumVisits' --this is where I add the zeros
			FROM 
			(SELECT DISTINCT PEWS_AgeGroup FROM #RSSP_PEWS_ED_Counts) X
			CROSS JOIN
			(SELECT DISTINCT FiscalPeriodLong FROM #RSSP_PEWS_ED_Counts) Y
			LEFT JOIN #RSSP_PEWS_ED_Counts as Z
			ON X.PEWS_AgeGroup=Z.PEWS_AgeGroup	--same age group
			AND Y.FiscalPeriodLong=Z.FiscalPeriodLong	--same fiscal period
		END

	----------------------
	--ID12 # of Acute Admits by PWES age buckets
	----------------------
	--PWES buckets
	--o   0-3 months
	--o   4-11 months
	--o   1-3 years 
	--o   4-6 years 
	--o   7-11 years 
	--o   12+ years

		/*
		create a table to house the data for easier pulling in the report.
		CREATE TABLE DSSI.dbo.RSSPDASH_PEWSCounts_Acute (
			FiscalPeriodLong varchar(255),
			PEWS_AgeGroup varchar(11),
			NumCases int
		)
		*/

		--compute # of cases by PEWS age group and store the results
		BEGIN IF OBJECT_ID('tempdb.dbo.#RSSP_PEWS_Acute_Counts') IS NOT NULL DROP TABLE #RSSP_PEWS_Acute_Counts END
	
		BEGIN
			SELECT D.FiscalPeriodLong
			,CASE	WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 0 AND 3 THEN '0-3 Months'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 4 AND 11 THEN '4-11 Months'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 12*1 AND 12*3 THEN '1-3 Years'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 12*3 AND 12*6 THEN '4-6 Years'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 12*6 AND 12*11 THEN '7-11 Years'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) >= 12*11 THEN '12+ Years'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) <0 THEN 'Start<BirthDate'
					ELSE 'Unknown'
			END as 'PEWS_AgeGroup'
			, COUNT(distinct I.AccountNumber) as 'NumCases'
			INTO #RSSP_PEWS_Acute_Counts
			FROM #consolidateIn as I
			LEFT JOIN ADTCMart.adtc.vwAdmissionDischargeFact as ADTC
			ON I.AccountNumber=ADTC.AccountNumber
			INNER JOIN #reportFP_SSPDash as D
			ON I.EntryDatetime BETWEEN D.FiscalPeriodStartDate AND D.FiscalPeriodEndDate
			GROUP BY D.FiscalPeriodLong
			,CASE	WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 0 AND 3 THEN '0-3 Months'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 4 AND 11 THEN '4-11 Months'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 12*1 AND 12*3 THEN '1-3 Years'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 12*3 AND 12*6 THEN '4-6 Years'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) BETWEEN 12*6 AND 12*11 THEN '7-11 Years'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) >= 12*11 THEN '12+ Years'
					WHEN DATEDIFF(month, [BirthDate], EntryDateTime) <0 THEN 'Start<BirthDate'
					ELSE 'Unknown'
			END
		END

		--clear historical table values
		BEGIN TRUNCATE TABLE DSSI.dbo.RSSPDASH_PEWSCounts_Acute END

		--needed to add 0's because not every period has someone in this age group.
		--I create a row for each expected combination based on data observered. Should be 0 if there is a non-0 for any group.
		--Happens Frequently because the unit only has 2 beds.
		BEGIN
			INSERT INTO DSSI.dbo.RSSPDASH_PEWSCounts_Acute (PEWS_AgeGroup, FiscalPeriodLong, NumCases)
			SELECT X.PEWS_AgeGroup
			, Y.FiscalPeriodLong
			, ISNULL(Z.NumCases,0) as 'NumCases' --this is where I add the zeros
			FROM 
			(SELECT DISTINCT PEWS_AgeGroup FROM #RSSP_PEWS_Acute_Counts) X
			CROSS JOIN
			(SELECT DISTINCT FiscalPeriodLong FROM #RSSP_PEWS_Acute_Counts) Y
			LEFT JOIN #RSSP_PEWS_Acute_Counts as Z
			ON X.PEWS_AgeGroup=Z.PEWS_AgeGroup	--same age group
			AND Y.FiscalPeriodLong=Z.FiscalPeriodLong	--same fiscal period
		END

	---------------------------
	-- Consolidate Results
	---------------------------
	/* 
	Tables to hold the indicator results for the dashboard
	Not all of the above though can feed into these indicator table.
	Top 10 EDDx, Top 10 CMG, and PEWS Age counts ED and Acute have been stored into 4 other tables as follows respectively.
	o DSSI.[dbo].[RSSPDASH_Top10EDDx_Current]
	o DSSI.[dbo].[RSSPDASH_Top10CMG_Current]
	o DSSI.[dbo].[RSSPDASH_PEWSCounts_ED]
	o DSSI.[dbo].[RSSPDASH_PEWSCounts_Acute]

	CREATE TABLE DSSI.dbo.RSSPDASH_MasterTableAll
	(	Facility char(50),
		TimeFrame char(50),
		IndicatorName char(255),
		Metric real,
		[Target] real,
		DesiredDirection char(5),
		[Format] char(2),
		TimeFrameType char(2),
		DataSource char(255),
		CONSTRAINT CK_RRSPDASH_MA_SingleMeassure UNIQUE( Facility, TimeFrame, IndicatorName)
	)

	CREATE TABLE DSSI.dbo.RSSPDASH_MasterTableMostRecent
	(	Facility char(50),
		TimeFrame char(50),
		IndicatorName char(255),
		Metric real,
		[Target] real,
		DesiredDirection char(5),
		[Format] char(2),
		TimeFrameType char(2),
		DataSource char(255),
		CONSTRAINT CK_RRSPDASH_MR_SingleMeassure UNIQUE( Facility, TimeFrame, IndicatorName)
	)
	*/

		--Clear out data from historical runs in the table
		BEGIN TRUNCATE TABLE DSSI.[dbo].[RSSPDASH_MasterTableAll] END
		BEGIN TRUNCATE TABLE DSSI.[dbo].[RSSPDASH_MasterTableMostRecent] END

		--Insert Data into the the all historty indicator table
		BEGIN
			INSERT INTO DSSI.[dbo].[RSSPDASH_MasterTableAll] ([Facility], [TimeFrame], [IndicatorName], [Metric], [Target], [DesiredDirection], [Format], [TimeFrameType], [DataSource])
			SELECT [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] FROM #ID01_RSSPDash	--has both FP and FY
			UNION
			SELECT [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] FROM #ID02_RSSPDash	--has both FP and FY
			UNION
			SELECT [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] FROM #ID03_RSSPDash	--has both FQ and FY
			UNION
			SELECT [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] FROM #ID04_RSSPDash	--has both FP and FY
			UNION
			SELECT [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] FROM #ID05_RSSPDash	--has both FP and FY
			UNION
			SELECT [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] FROM #ID06_RSSPDash	--has both FP and FY
		END

		--Insert Data into the Most Recent Indicators Table.
		BEGIN
			INSERT INTO DSSI.[dbo].[RSSPDASH_MasterTableMostRecent] ([Facility], [TimeFrame], [IndicatorName], [Metric], [Target], [DesiredDirection], [Format], [TimeFrameType], [DataSource])
			--1st indicator
			SELECT * FROM (
				SELECT TOP 1 [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] 
				FROM #ID01_RSSPDash	--has both FP and FY
				WHERE #ID01_RSSPDash.TimeFrameType='P'
				ORDER BY TimeFrame DESC
			) X1
			UNION
			--2nd indicator
			SELECT * FROM (
				SELECT TOP 1 [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] 
				FROM #ID02_RSSPDash	--has both FP and FY
				WHERE #ID02_RSSPDash.TimeFrameType='P'
				ORDER BY TimeFrame DESC
			) X2
			UNION
			--3rd indicator
			SELECT * FROM (
				SELECT TOP 1 [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] 
				FROM #ID03_RSSPDash	--has both FQ and FY
				WHERE #ID03_RSSPDash.TimeFrameType='Q'
				ORDER BY TimeFrame DESC
			) X3
			UNION
			--4th indicator
			SELECT * FROM (
				SELECT TOP 1 [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] 
				FROM #ID04_RSSPDash	--has both FP and FY
				WHERE #ID04_RSSPDash.TimeFrameType='P'
				ORDER BY TimeFrame DESC
			) X4
			UNION
			--5th indicator
			SELECT * FROM (
				SELECT TOP 1 [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] 
				FROM #ID05_RSSPDash	--has both FP and FY
				WHERE #ID05_RSSPDash.TimeFrameType='P'
				ORDER BY TimeFrame DESC
			) X5
			UNION
			--6th indicator
			SELECT * FROM (
				SELECT TOP 1 [Facility],[TimeFrame],[IndicatorName],[Metric],[Target],[DesiredDirection],[Format],[TimeFrameType],[DataSource] 
				FROM #ID06_RSSPDash	--has both FP and FY
				WHERE #ID06_RSSPDash.TimeFrameType='P'
				ORDER BY TimeFrame DESC
			) X6
		END

	-------------------
	--END OF QUERY
	-------------------
END

