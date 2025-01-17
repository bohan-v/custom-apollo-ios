import Foundation
#if !COCOAPODS
import CustomApolloAPI
#endif

struct FieldSelectionGrouping: Sequence {
  private var fieldInfoList: [String: FieldExecutionInfo] = [:]
  fileprivate(set) var fulfilledFragments: Set<ObjectIdentifier> = []

  init(info: ObjectExecutionInfo) {
    self.fulfilledFragments = info.fulfilledFragments
  }

  var count: Int { fieldInfoList.count }

  mutating func append(field: Selection.Field, withInfo info: ObjectExecutionInfo) {
    let fieldKey = field.responseKey
    if var fieldInfo = fieldInfoList[fieldKey] {
      fieldInfo.mergedFields.append(field)
      fieldInfoList[fieldKey] = fieldInfo
    } else {
      fieldInfoList[fieldKey] = FieldExecutionInfo(field: field, parentInfo: info)
    }
  }

  mutating func addFulfilledFragment<T: SelectionSet>(_ type: T.Type) {
    fulfilledFragments.insert(ObjectIdentifier(type))
  }

  func makeIterator() -> Dictionary<String, FieldExecutionInfo>.Iterator {
    fieldInfoList.makeIterator()
  }
}

protocol FieldSelectionCollector {

  /// Groups fields that share the same response key for simultaneous resolution.
  ///
  /// Before execution, the selection set is converted to a grouped field set.
  /// Each entry in the grouped field set is a list of fields that share a response key.
  /// This ensures all fields with the same response key (alias or field name) included via
  /// referenced fragments are executed at the same time.
  func collectFields(
    from selections: [Selection],
    into groupedFields: inout FieldSelectionGrouping,
    for object: JSONObject,
    info: ObjectExecutionInfo
  ) throws

}

struct DefaultFieldSelectionCollector: FieldSelectionCollector {
  func collectFields(
    from selections: [Selection],
    into groupedFields: inout FieldSelectionGrouping,
    for object: JSONObject,
    info: ObjectExecutionInfo
  ) throws {
    for selection in selections {
      switch selection {
      case let .field(field):
        groupedFields.append(field: field, withInfo: info)

      case let .conditional(conditions, conditionalSelections):
        if conditions.evaluate(with: info.variables) {
          try collectFields(from: conditionalSelections,
                            into: &groupedFields,
                            for: object,
                            info: info)
        }

      case let .fragment(fragment):
        groupedFields.addFulfilledFragment(fragment)
        try collectFields(from: fragment.__selections,
                          into: &groupedFields,
                          for: object,
                          info: info)

      case let .inlineFragment(typeCase):
        if let runtimeType = info.runtimeObjectType(for: object),
           typeCase.__parentType.canBeConverted(from: runtimeType) {
          groupedFields.addFulfilledFragment(typeCase)
          try collectFields(from: typeCase.__selections,
                            into: &groupedFields,
                            for: object,
                            info: info)
        }
      }
    }
  }
}

/// This field collector is intended for usage when writing custom selection set data to the cache.
/// It is used by the cache writing APIs in ``ApolloStore/ReadWriteTransaction``.
///
/// This ``FieldSelectionCollector`` attempts to write all of the given object data to the cache.
/// It collects fields that are wrapped in inclusion conditions if data for the field exists,
/// ignoring the inclusion condition and variables. This ensures that object data for these fields
/// will be written to the cache.
struct CustomCacheDataWritingFieldSelectionCollector: FieldSelectionCollector {
  enum Error: Swift.Error {
    case fulfilledFragmentsMissing
  }

  func collectFields(
    from selections: [Selection],
    into groupedFields: inout FieldSelectionGrouping,
    for object: JSONObject,
    info: ObjectExecutionInfo
  ) throws {
    try collectFields(
      from: selections,
      into: &groupedFields,
      for: object,
      info: info,
      asConditionalFields: false
    )
  }

  func collectFields(
    from selections: [Selection],
    into groupedFields: inout FieldSelectionGrouping,
    for object: JSONObject,
    info: ObjectExecutionInfo,
    asConditionalFields: Bool
  ) throws {
    guard let fulfilledFragments = object["__fulfilled"] as? Set<ObjectIdentifier> else {
      throw GraphQLExecutionError(
        path: info.responsePath,
        underlying: Error.fulfilledFragmentsMissing
      )
    }
    groupedFields.fulfilledFragments = fulfilledFragments

    for selection in selections {
      switch selection {
      case let .field(field):
        if asConditionalFields && !field.type.isNullable {
          guard let value = object[field.responseKey], !(value is NSNull) else {
            continue
          }
        }
        groupedFields.append(field: field, withInfo: info)

      case let .conditional(_, conditionalSelections):
        try collectFields(from: conditionalSelections,
                          into: &groupedFields,
                          for: object,
                          info: info,
                          asConditionalFields: true)

      case let .fragment(fragment):
        if groupedFields.fulfilledFragments.contains(type: fragment) {
          try collectFields(from: fragment.__selections,
                            into: &groupedFields,
                            for: object,
                            info: info,
                            asConditionalFields: false)
        }

      case let .inlineFragment(typeCase):
        if groupedFields.fulfilledFragments.contains(type: typeCase) {
          try collectFields(from: typeCase.__selections,
                            into: &groupedFields,
                            for: object,
                            info: info,
                            asConditionalFields: false)
        }
      }
    }
  }
}

fileprivate extension Set<ObjectIdentifier> {
  func contains(type: Any.Type) -> Bool {
    contains(ObjectIdentifier(type.self))
  }
}
